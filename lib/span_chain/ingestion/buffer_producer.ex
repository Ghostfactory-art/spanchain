defmodule SpanChain.Ingestion.BufferProducer do
  @moduledoc """
  In-memory GenStage `:producer`. Receives hashed Ledger entries from the
  SessionGenServer (`enqueue/1` cast, fire-and-forget) and emits them to the Broadway
  pipeline based on demand. Holds a `:queue` + a pending demand counter.

  ## Discovery via Registry

  In the supervision tree Broadway spawns the producer process under its internal
  name (e.g. `Pipeline.Broadway.Producer_0`) — not under `__MODULE__`. So that the SGS
  knows where to cast, BufferProducer.init/1 registers its pid in
  `SpanChain.Ingestion.BufferRegistry` under the key `:singleton`.
  `enqueue/1` does a `Registry.lookup` + `GenStage.cast`.

  For tests, `enqueue(pid, entries)` is arity-2 — it bypasses the Registry,
  casting directly to the given pid (an isolated instance without Registry registration).

  ## Ordering guarantee

  Erlang FIFO between the SGS and the producer process + `:queue.in/out` FIFO +
  Broadway `partition_by: run_id` in the processor = entries for a given `run_id`
  arrive in the DB in insertion order.

  ## The buffer is not persisted

  A process restart = loss of in-flight entries. Acceptable for L2;
  L3 will move to a persistent queue (GF-648 NATS JetStream).
  """

  use GenStage

  @registry SpanChain.Ingestion.BufferRegistry
  @registry_key :singleton

  @type entry :: SpanChain.Ledger.entry()
  @type state :: %{queue: :queue.queue(), demand: non_neg_integer()}

  @doc """
  Standalone start — for tests that want an isolated BufferProducer instance
  (without Registry registration; bypasses the singleton pattern). On the production path
  BufferProducer is started by Broadway inside its supervision tree via `init/1`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenStage.start_link(__MODULE__, {:standalone, name}, name: name)
  end

  @doc """
  Cast batch entries into the singleton producer queue (via Registry lookup).
  Fire-and-forget — does not block the caller. Called from SessionGenServer.handle_call
  after build_entries.
  """
  @spec enqueue([entry()]) :: :ok | {:error, :no_producer}
  def enqueue(entries) when is_list(entries) do
    case Registry.lookup(@registry, @registry_key) do
      [{pid, _}] -> GenStage.cast(pid, {:enqueue, entries})
      [] -> {:error, :no_producer}
    end
  end

  @doc "Cast directly to a specific pid — for tests with an isolated BufferProducer instance."
  @spec enqueue(GenServer.server(), [entry()]) :: :ok
  def enqueue(pid, entries) when is_list(entries) do
    GenStage.cast(pid, {:enqueue, entries})
  end

  # Broadway calls init/1 with a keyword list of opts (containing broadway: [index: 0, ...] +
  # those from `producer: [module: {BufferProducer, []}]`). On the production path
  # we register self in the singleton Registry for SGS discovery.
  @impl true
  def init(opts) when is_list(opts) do
    {:ok, _} = Registry.register(@registry, @registry_key, nil)
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  # Standalone start (tests) — no Registry registration, just producer state.
  @impl true
  def init({:standalone, _name}) do
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_cast({:enqueue, entries}, state) do
    messages = Enum.map(entries, &to_broadway_message/1)
    new_queue = Enum.reduce(messages, state.queue, fn msg, q -> :queue.in(msg, q) end)
    dispatch(%{state | queue: new_queue})
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    dispatch(%{state | demand: state.demand + demand})
  end

  defp dispatch(%{demand: 0} = state), do: {:noreply, [], state}

  defp dispatch(%{queue: queue, demand: demand} = state) do
    {items, remaining_queue} = take(queue, demand, [])
    remaining_demand = demand - length(items)
    {:noreply, items, %{state | queue: remaining_queue, demand: remaining_demand}}
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> take(rest, n - 1, [item | acc])
      {:empty, _} -> {Enum.reverse(acc), queue}
    end
  end

  defp to_broadway_message(entry) do
    %Broadway.Message{
      data: entry,
      # NoopAcknowledger.ack/3 pattern-matches exclusively on a nil ack_ref —
      # `Broadway.NoopAcknowledger.init/0` returns the canonical `{Mod, nil, nil}`.
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end
end
