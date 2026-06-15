defmodule SpanChain.Evals do
  @moduledoc """
  Public API for the Evals domain (GF-706). An Eval is an umbrella aggregate for
  comparing multiple `runs` with the same intent.

  Depends on the `SpanChain.Eval` schema + the `SpanChain.Run.eval_id` FK.
  The compare function delegates to `SpanChain.Evals.Comparator` (pure logic).
  """

  import Ecto.Query

  require Logger

  alias SpanChain.{Eval, Repo, Run}
  alias SpanChain.Evals.Comparator

  @doc """
  GF-868: upsert an eval's human-readable name from the OTLP `gf.eval.name` resource
  attribute. Best-effort (never raises, must not block ingestion):

    * `eval_name` present → `on_conflict: replace [:name]` — create or update the name.
    * `eval_name` nil → create-only with `name = eval_id` (UI fallback); `on_conflict: :nothing`
      leaves an existing real name untouched (first-real-name-wins).
  """
  @spec ensure_eval_name(String.t(), String.t() | nil) :: :ok
  def ensure_eval_name(eval_id, eval_name) when is_binary(eval_id) do
    name = eval_name || eval_id
    on_conflict = if eval_name, do: [set: [name: eval_name]], else: :nothing

    Repo.insert(%Eval{eval_id: eval_id, name: name, status: "running"},
      on_conflict: on_conflict,
      conflict_target: :eval_id
    )

    :ok
  rescue
    e ->
      Logger.warning("[Evals] ensure_eval_name rescued #{inspect(e)}")
      :ok
  end

  @spec create_eval(map()) :: {:ok, Eval.t()} | {:error, Ecto.Changeset.t()}
  def create_eval(attrs) when is_map(attrs) do
    %Eval{}
    |> Eval.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_eval(String.t()) :: Eval.t() | nil
  def get_eval(eval_id) when is_binary(eval_id) do
    Eval
    |> Repo.get(eval_id)
    |> case do
      nil -> nil
      eval -> Repo.preload(eval, :runs)
    end
  end

  @spec list_run_ids(String.t()) :: [String.t()]
  def list_run_ids(eval_id) when is_binary(eval_id) do
    from(r in Run, where: r.eval_id == ^eval_id, select: r.run_id)
    |> Repo.all()
  end

  defdelegate compare(run_id_a, run_id_b), to: Comparator
end
