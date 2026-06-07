defmodule SpanChain.Evals do
  @moduledoc """
  Public API pro Evals doménu (GF-706). Eval je zastřešující agregát pro
  porovnávání více `runs` se stejným záměrem.

  Závisí na `SpanChain.Eval` schema + `SpanChain.Run.eval_id` FK.
  Compare funkce deleguje na `SpanChain.Evals.Comparator` (pure logika).
  """

  import Ecto.Query

  alias SpanChain.{Eval, Repo, Run}
  alias SpanChain.Evals.Comparator

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
