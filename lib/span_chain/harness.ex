defmodule SpanChain.Harness do
  @moduledoc """
  An observability wrapper around arbitrary customer code — it wraps
  a `GenServer`, `Task`, a plain function, etc. and automatically sends spans to the
  Ledger via `SessionGenServer` (same node, no HTTP roundtrip).

  The Harness **is not an agent framework**: it does not dictate how the customer's code
  manages its state. It holds only an `active_spans` map and forwards finished spans on.

  ## Example

      {:ok, h} = SpanChain.Harness.start_link(run_id: "demo-run")

      result = SpanChain.Harness.with_span(h, "agent_run", %{task: "hello"}, fn ->
        "world"
      end)
      # => "world"  (the result is returned transparently)

      :ok = SpanChain.Harness.stop(h)

  Nested spans via an explicit `parent_span_id` (the Harness holds no
  global stack — a parallel `Task.async` would break it):

      {:ok, parent_id} = SpanChain.Harness.start_span(h, "agent_run", %{})

      SpanChain.Harness.with_span(h, "llm_call", %{},
        [parent_span_id: parent_id], fn ->
        # ...
      end)

      :ok = SpanChain.Harness.end_span(h, parent_id, %{status: :ok})

  An exception inside `with_span` is logged into the span as
  `%{status: :error, error: inspect(e)}` and then **reraised** —
  the Harness never swallows the customer's exceptions ("let it crash").
  """

  use GenServer

  alias SpanChain.Ingestion.{SessionGenServer, SessionSupervisor}
  alias SpanChain.PayloadSerializer

  @type span_id :: String.t()

  @type active_span :: %{
          name: String.t(),
          started_at: DateTime.t(),
          parent_span_id: span_id() | nil,
          attributes: map()
        }

  @type state :: %{
          run_id: String.t(),
          active_spans: %{span_id() => active_span()},
          completed_count: non_neg_integer()
        }

  # --------------------------------------------------------------------------
  # Client API
  # --------------------------------------------------------------------------

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, %{run_id: run_id})
  end

  @doc """
  Opens a span. Returns `{:ok, span_id}`. `parent_span_id` is passed in `opts`
  (explicit; no auto-stack).
  """
  @spec start_span(GenServer.server(), String.t(), map(), keyword()) :: {:ok, span_id()}
  def start_span(pid, name, attributes \\ %{}, opts \\ []) when is_map(attributes) do
    parent_span_id = Keyword.get(opts, :parent_span_id)
    GenServer.call(pid, {:start_span, name, attributes, parent_span_id})
  end

  @doc """
  Closes a span and sends it to the SessionGenServer. `end_attrs` is merged into
  the start_attrs `attributes` — typically `%{status: :ok}` or `%{status: :error}`.
  """
  @spec end_span(GenServer.server(), span_id(), map()) :: :ok | {:error, :unknown_span_id}
  def end_span(pid, span_id, end_attrs \\ %{}) when is_map(end_attrs) do
    GenServer.call(pid, {:end_span, span_id, end_attrs})
  end

  @doc """
  Higher-order function: opens a span, runs `fun.()`, closes the span with the result.
  Propagates exceptions outward after logging them into the span.

  Returns the function's result directly — `with_span` is a transparent wrapper.
  """
  def with_span(pid, name, attributes, fun) when is_function(fun, 0) do
    with_span(pid, name, attributes, [], fun)
  end

  def with_span(pid, name, attributes, opts, fun)
      when is_list(opts) and is_function(fun, 0) do
    {:ok, span_id} = start_span(pid, name, attributes, opts)

    try do
      result = fun.()
      :ok = end_span(pid, span_id, %{status: :ok, result: inspect(result)})
      result
    rescue
      e ->
        :ok = end_span(pid, span_id, %{status: :error, error: inspect(e)})
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        :ok = end_span(pid, span_id, %{status: :error, error: inspect({kind, reason})})
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Stops the Harness. `terminate/2` flushes all `active_spans` as abandoned."
  @spec stop(GenServer.server()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal)

  # --------------------------------------------------------------------------
  # Server callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(%{run_id: run_id}) do
    {:ok, _session_pid} = SessionSupervisor.ensure_session(run_id)

    state = %{
      run_id: run_id,
      active_spans: %{},
      completed_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_span, name, attributes, parent_span_id}, _from, state) do
    span_id = generate_span_id()

    active = %{
      name: name,
      started_at: DateTime.utc_now(),
      parent_span_id: parent_span_id,
      attributes: attributes
    }

    {:reply, {:ok, span_id}, put_in(state.active_spans[span_id], active)}
  end

  @impl true
  def handle_call({:end_span, span_id, end_attrs}, _from, state) do
    case Map.pop(state.active_spans, span_id) do
      {nil, _} ->
        {:reply, {:error, :unknown_span_id}, state}

      {active, rest_spans} ->
        span_map = build_span_map(span_id, active, end_attrs, DateTime.utc_now())
        SessionGenServer.ingest_spans(state.run_id, [span_map])

        state = %{
          state
          | active_spans: rest_spans,
            completed_count: state.completed_count + 1
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{active_spans: spans}) when map_size(spans) == 0, do: :ok

  def terminate(_reason, state) do
    ended_at = DateTime.utc_now()

    span_maps =
      Enum.map(state.active_spans, fn {span_id, active} ->
        build_span_map(span_id, active, %{status: :abandoned}, ended_at)
      end)

    SessionGenServer.ingest_spans(state.run_id, span_maps)
    :ok
  end

  # --------------------------------------------------------------------------
  # Private
  # --------------------------------------------------------------------------

  defp build_span_map(span_id, active, end_attrs, ended_at) do
    duration_ms = DateTime.diff(ended_at, active.started_at, :millisecond)
    attrs = stringify_keys(Map.merge(active.attributes, end_attrs))

    %{
      "span_id" => span_id,
      "name" => active.name,
      "started_at" => DateTime.to_iso8601(active.started_at),
      "ended_at" => DateTime.to_iso8601(ended_at),
      "parent_span_id" => active.parent_span_id,
      "duration_ms" => duration_ms,
      "attributes" => attrs
    }
  end

  defp generate_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), PayloadSerializer.serialize_value(v)} end)
  end
end
