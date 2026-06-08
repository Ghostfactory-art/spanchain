defmodule SpanChain.Orchestrator do
  @moduledoc """
  The Orchestrator as a GenServer.

  Responsible for:
  - spawning agents via the DynamicSupervisor
  - routing tasks to the right agents
  - aggregating the Trail (an overview of all runs)
  - basic load balancing (round-robin over idle agents)

  This is the seed of the ROMA Planner from the GF AOS architecture.
  """

  use GenServer
  require Logger

  alias SpanChain.Agent

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, initial_state(), name: __MODULE__)
  end

  @doc "Spawns a new agent. Returns the agent_id."
  def spawn_agent(name \\ nil) do
    GenServer.call(__MODULE__, {:spawn_agent, name})
  end

  @doc "Runs a task on a specific agent."
  def run_task(agent_id, task) do
    GenServer.call(__MODULE__, {:run_task, agent_id, task}, 60_000)
  end

  @doc "Runs a task on the first idle agent (round-robin)."
  def dispatch(task) do
    GenServer.call(__MODULE__, {:dispatch, task}, 60_000)
  end

  @doc "Runs the same task on multiple agents in parallel. The basis for evals."
  def eval_run(task, agent_ids) do
    GenServer.call(__MODULE__, {:eval_run, task, agent_ids}, 120_000)
  end

  @doc "Returns the whole Trail — all runs with their Ledgers."
  def get_trail do
    GenServer.call(__MODULE__, :get_trail)
  end

  @doc "Returns an overview of all agents."
  def list_agents do
    GenServer.call(__MODULE__, :list_agents)
  end

  @doc "Prints the Trail neatly to the console."
  def print_trail do
    trail = get_trail()

    IO.puts("\n" <> String.duplicate("═", 60))
    IO.puts("  GhostFactory Trail")
    IO.puts(String.duplicate("═", 60))
    IO.puts("  Agents:    #{map_size(trail.agents)}")
    IO.puts("  Runs:      #{length(trail.runs)}")
    IO.puts("  Success:   #{Enum.count(trail.runs, &(&1.status == :ok))}")
    IO.puts("  Failed:    #{Enum.count(trail.runs, &(&1.status == :error))}")
    IO.puts(String.duplicate("─", 60))

    trail.runs
    |> Enum.each(fn run ->
      status_icon = if run.status == :ok, do: "✓", else: "✗"
      IO.puts("  #{status_icon} Run #{run.id}")
      IO.puts("    Agent:    #{run.agent_id}")
      IO.puts("    Task:     #{inspect(run.task)}")
      IO.puts("    Duration: #{run.duration_ms}ms")
      IO.puts("    Ledger:   #{length(run.ledger)} entries")
      IO.puts("")
    end)

    IO.puts(String.duplicate("═", 60) <> "\n")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state) do
    Logger.info("[Orchestrator] Started")
    {:ok, state}
  end

  @impl true
  def handle_call({:spawn_agent, name}, _from, state) do
    id = generate_id()
    name = name || "agent-#{id}"

    spec = {SpanChain.Agent, [id: id, name: name]}

    case DynamicSupervisor.start_child(SpanChain.AgentSupervisor, spec) do
      {:ok, pid} ->
        Logger.info("[Orchestrator] Spawned agent #{id} (#{name}), pid=#{inspect(pid)}")

        agent_info = %{id: id, name: name, pid: pid, spawned_at: DateTime.utc_now()}
        state = put_in(state, [:agents, id], agent_info)
        {:reply, {:ok, id}, state}

      {:error, reason} ->
        Logger.error("[Orchestrator] Failed to spawn agent: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_task, agent_id, task}, _from, state) do
    {run, state} = execute_run(agent_id, task, state)
    {:reply, {:ok, run}, state}
  end

  @impl true
  def handle_call({:dispatch, task}, _from, state) do
    case pick_idle_agent(state) do
      nil ->
        {:reply, {:error, :no_idle_agents}, state}

      agent_id ->
        {run, state} = execute_run(agent_id, task, state)
        {:reply, {:ok, run}, state}
    end
  end

  @impl true
  def handle_call({:eval_run, task, agent_ids}, _from, state) do
    # Parallel execution across multiple agents — the basis for evals
    # Each agent gets the same task, the results are compared
    results =
      agent_ids
      |> Task.async_stream(
        fn agent_id ->
          started = DateTime.utc_now()
          result = Agent.run(agent_id, task)
          ledger = Agent.get_ledger(agent_id)

          %{
            agent_id: agent_id,
            result: result,
            ledger: ledger,
            duration_ms: DateTime.diff(DateTime.utc_now(), started, :millisecond)
          }
        end,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn {:ok, r} -> r end)

    eval_summary = %{
      id: generate_id(),
      task: task,
      agent_ids: agent_ids,
      results: results,
      ran_at: DateTime.utc_now()
    }

    state = update_in(state, [:evals], &[eval_summary | &1])
    {:reply, {:ok, eval_summary}, state}
  end

  @impl true
  def handle_call(:get_trail, _from, state) do
    trail = %{
      agents: state.agents,
      runs: Enum.reverse(state.runs),
      evals: Enum.reverse(state.evals)
    }

    {:reply, trail, state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    {:reply, state.agents, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp execute_run(agent_id, task, state) do
    started_at = DateTime.utc_now()
    reply = Agent.run(agent_id, task)
    ended_at = DateTime.utc_now()
    ledger = Agent.get_ledger(agent_id)

    {result, status} =
      case reply do
        {:ok, r} -> {r, :ok}
        {:error, e} -> {e, :error}
      end

    run = %{
      id: generate_id(),
      agent_id: agent_id,
      task: task,
      result: result,
      status: status,
      ledger: ledger,
      started_at: started_at,
      ended_at: ended_at,
      duration_ms: DateTime.diff(ended_at, started_at, :millisecond)
    }

    state = update_in(state, [:runs], &[run | &1])
    {run, state}
  end

  defp pick_idle_agent(state) do
    # Simplified: returns an arbitrary agent
    # In production: check the status via Agent.get_state/1
    case Map.keys(state.agents) do
      [] -> nil
      [id | _] -> id
    end
  end

  defp initial_state do
    %{
      agents: %{},
      runs: [],
      evals: []
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
