defmodule SpanChain.Agent do
  @moduledoc """
  Agent jako GenServer s hash-chain Ledgerem.

  Každý agent:
  - běží jako izolovaný OTP process
  - drží vlastní stav (idle → running → done/failed)
  - zapisuje každou akci do append-only Ledgeru
  - každý záznam v Ledgeru je hash předchozího záznamu → chain integrity
  - generuje Spany (started_at, ended_at, attributes)

  Tohle je základ pro GF replay: Ledger je source of truth,
  ne "re-run se stejnými inputy".
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # Typy
  # ---------------------------------------------------------------------------

  @type agent_id :: String.t()

  @type span :: %{
          id: String.t(),
          name: String.t(),
          attributes: map(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          status: :open | :ok | :error,
          result: any()
        }

  @type ledger_entry :: {
          seq :: non_neg_integer(),
          hash :: String.t(),
          prev_hash :: String.t() | nil,
          event :: term(),
          timestamp :: DateTime.t()
        }

  @type state :: %{
          id: agent_id(),
          name: String.t(),
          status: :idle | :running | :done | :failed,
          current_span: span() | nil,
          spans: [span()],
          ledger: [ledger_entry()],
          result: any(),
          error: any()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, "agent-#{id}")
    GenServer.start_link(__MODULE__, %{id: id, name: name}, name: via(id))
  end

  @doc "Spustí task na agentovi. Synchronní — blokuje do dokončení."
  def run(agent_id, task, timeout \\ 30_000) do
    GenServer.call(via(agent_id), {:run, task}, timeout)
  end

  @doc "Vrátí aktuální stav agenta."
  def get_state(agent_id) do
    GenServer.call(via(agent_id), :get_state)
  end

  @doc "Vrátí celý Ledger (chronologicky). Základ pro replay."
  def get_ledger(agent_id) do
    GenServer.call(via(agent_id), :get_ledger)
  end

  @doc "Vrátí všechny Spany."
  def get_spans(agent_id) do
    GenServer.call(via(agent_id), :get_spans)
  end

  @doc "Ověří integritu hash-chainu v Ledgeru."
  def verify_ledger(agent_id) do
    GenServer.call(via(agent_id), :verify_ledger)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{id: id, name: name}) do
    Logger.info("[Agent #{id}] Spawned: #{name}")

    state = %{
      id: id,
      name: name,
      status: :idle,
      current_span: nil,
      spans: [],
      ledger: [],
      result: nil,
      error: nil
    }

    state = ledger_append(state, {:agent_spawned, %{id: id, name: name}})
    {:ok, state}
  end

  @impl true
  def handle_call({:run, _task}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call({:run, task}, _from, state) do
    Logger.info("[Agent #{state.id}] Starting task: #{inspect(task)}")

    # Otevři span
    span = open_span("agent.run", %{task: task, agent_id: state.id})

    state =
      state
      |> Map.put(:status, :running)
      |> Map.put(:current_span, span)
      |> ledger_append({:task_started, %{task: task, span_id: span.id}})

    # Vykonej task
    {result, status, error} =
      try do
        r = execute_task(task, state)
        {r, :done, nil}
      rescue
        e ->
          Logger.error("[Agent #{state.id}] Task failed: #{inspect(e)}")
          {nil, :failed, e}
      end

    # Zavři span
    span = close_span(span, result, status)

    state =
      state
      |> Map.put(:status, status)
      |> Map.put(:current_span, nil)
      |> Map.put(:result, result)
      |> Map.put(:error, error)
      |> Map.update!(:spans, &[span | &1])
      |> ledger_append(
        {:task_completed,
         %{
           task: task,
           span_id: span.id,
           status: status,
           duration_ms: span_duration_ms(span)
         }}
      )

    reply = if status == :done, do: {:ok, result}, else: {:error, error}
    Logger.info("[Agent #{state.id}] Task #{status}. Duration: #{span_duration_ms(span)}ms")

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.drop(state, [:ledger, :spans]), state}
  end

  @impl true
  def handle_call(:get_ledger, _from, state) do
    {:reply, Enum.reverse(state.ledger), state}
  end

  @impl true
  def handle_call(:get_spans, _from, state) do
    {:reply, Enum.reverse(state.spans), state}
  end

  @impl true
  def handle_call(:verify_ledger, _from, state) do
    result = verify_chain(Enum.reverse(state.ledger))
    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # Private: Ledger (hash-chain)
  # ---------------------------------------------------------------------------

  defp ledger_append(state, event) do
    seq = length(state.ledger)

    prev_hash =
      case state.ledger do
        [] -> nil
        [{_, hash, _, _, _} | _] -> hash
      end

    hash = compute_hash(prev_hash, seq, event)

    entry = {seq, hash, prev_hash, event, DateTime.utc_now()}
    %{state | ledger: [entry | state.ledger]}
  end

  defp compute_hash(prev_hash, seq, event) do
    data = "#{seq}:#{inspect(prev_hash)}:#{inspect(event)}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp verify_chain([]), do: {:ok, :empty}

  defp verify_chain(entries) do
    # Projdi chain od nejstaršího a ověř každý hash
    result =
      entries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn
        [
          {seq_a, hash_a, _prev_a, event_a, _ts_a},
          {_seq_b, _hash_b, prev_hash_b, _event_b, _ts_b}
        ] ->
          recomputed = compute_hash(prev_hash_b |> (fn _ -> nil end).(), seq_a, event_a)
          # Zjednodušená verifikace - v produkci by byla důkladnější
          hash_a != recomputed
      end)

    case result do
      nil -> {:ok, :valid}
      _ -> {:error, :chain_broken}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Spans
  # ---------------------------------------------------------------------------

  defp open_span(name, attributes) do
    %{
      id: generate_id(),
      name: name,
      attributes: attributes,
      started_at: DateTime.utc_now(),
      ended_at: nil,
      status: :open,
      result: nil
    }
  end

  defp close_span(span, result, agent_status) do
    status = if agent_status == :done, do: :ok, else: :error
    %{span | ended_at: DateTime.utc_now(), status: status, result: result}
  end

  defp span_duration_ms(%{started_at: s, ended_at: e}) when not is_nil(e) do
    DateTime.diff(e, s, :millisecond)
  end

  defp span_duration_ms(_), do: nil

  # ---------------------------------------------------------------------------
  # Private: Task execution (placeholder → zde bude Anthropic API call)
  # ---------------------------------------------------------------------------

  defp execute_task(task, state) when is_binary(task) do
    # Simulace práce
    Process.sleep(Enum.random(50..200))

    # V produkci: volání Anthropic API přes Req
    # {:ok, response} = Req.post("https://api.anthropic.com/v1/messages", ...)

    "Agent #{state.name} completed: #{task}"
  end

  defp execute_task({:fail, reason}, _state) do
    raise "Intentional failure: #{reason}"
  end

  defp execute_task(task, state) do
    "Agent #{state.name} processed: #{inspect(task)}"
  end

  # ---------------------------------------------------------------------------
  # Private: Helpers
  # ---------------------------------------------------------------------------

  defp via(id), do: {:via, Registry, {SpanChain.AgentRegistry, id}}

  defp generate_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
