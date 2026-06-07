defmodule SpanChain.Evals.Router do
  @moduledoc """
  HTTP API pro Evals doménu (GF-706). Sub-router forwardovaný z hlavního
  `Ingestion.Router` na `/evals/*`. AuthPlug už proběhl v hlavním routeru,
  takže všechny zde definované routes jsou autentizované.

  Routes:
    * `POST /` — vytvoří nový Eval (201 / 400)
    * `GET /:eval_id` — detail Evalu s run_count / run_ids (200 / 404)
    * `GET /:eval_id/compare?run_a=X&run_b=Y` — strukturální diff dvou runů
  """

  use Plug.Router

  alias SpanChain.Evals

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/" do
    case Evals.create_eval(conn.body_params || %{}) do
      {:ok, eval} ->
        body = %{
          "eval_id" => eval.eval_id,
          "name" => eval.name,
          "status" => eval.status,
          "created_at" => NaiveDateTime.to_iso8601(eval.inserted_at)
        }

        put_json_resp(conn, 201, body)

      {:error, %Ecto.Changeset{errors: errors}} ->
        msg =
          if Keyword.has_key?(errors, :eval_id),
            do: "eval_id is required",
            else: "validation failed"

        put_json_resp(conn, 400, %{"error" => msg})
    end
  end

  get "/:eval_id" do
    case Evals.get_eval(eval_id) do
      nil ->
        put_json_resp(conn, 404, %{"error" => "eval not found"})

      eval ->
        body = %{
          "eval_id" => eval.eval_id,
          "status" => eval.status,
          "run_count" => length(eval.runs),
          "run_ids" => Enum.map(eval.runs, & &1.run_id)
        }

        put_json_resp(conn, 200, body)
    end
  end

  get "/:eval_id/compare" do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params do
      %{"run_a" => run_a, "run_b" => run_b} ->
        case Evals.compare(run_a, run_b) do
          {:ok, diff} ->
            put_json_resp(conn, 200, diff)

          {:error, :run_not_found} ->
            put_json_resp(conn, 404, %{"error" => "run not found"})

          {:error, :different_eval} ->
            put_json_resp(conn, 400, %{"error" => "runs belong to different evals"})
        end

      _ ->
        put_json_resp(conn, 400, %{"error" => "run_a and run_b query params required"})
    end
  end

  match _ do
    put_json_resp(conn, 404, %{"error" => "not found"})
  end

  defp put_json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
