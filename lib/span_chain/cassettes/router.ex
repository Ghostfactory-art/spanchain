defmodule SpanChain.Cassettes.Router do
  @moduledoc """
  HTTP API for the Cassettes domain (GF-712). A sub-router forwarded from the main
  `Ingestion.Router` to `/cassettes/*`. AuthPlug has already run in the main
  router.

  Routes:
    * `POST /record` — record a cassette from an existing run (201 / 400 / 404)
    * `GET /:cassette_id` — detail + spans (200 / 404)
    * `GET /` — list of metadata ordered by `recorded_at DESC` (200)
    * `POST /:cassette_id/replay` — replay a cassette under a new run_id
      (200 / 404 / 408)
  """

  use Plug.Router

  alias SpanChain.Cassettes

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/record" do
    params = conn.body_params || %{}
    run_id = params["run_id"]
    cassette_id = params["cassette_id"]
    name = params["name"]

    cond do
      not is_binary(run_id) or run_id == "" ->
        put_json_resp(conn, 400, %{"error" => "run_id is required"})

      not is_binary(cassette_id) or cassette_id == "" ->
        put_json_resp(conn, 400, %{"error" => "cassette_id is required"})

      true ->
        case Cassettes.record(run_id, cassette_id: cassette_id, name: name) do
          {:ok, cassette} ->
            body = %{
              "cassette_id" => cassette.cassette_id,
              "run_id" => cassette.run_id,
              "name" => cassette.name,
              "span_count" => length(cassette.snapshot),
              "recorded_at" => DateTime.to_iso8601(cassette.recorded_at)
            }

            put_json_resp(conn, 201, body)

          {:error, :run_not_found} ->
            put_json_resp(conn, 404, %{"error" => "run has no ledger rows"})

          {:error, %Ecto.Changeset{}} ->
            put_json_resp(conn, 400, %{"error" => "validation failed"})
        end
    end
  end

  get "/" do
    cassettes = Cassettes.list()

    body = %{
      "cassettes" =>
        Enum.map(cassettes, fn c ->
          %{
            "cassette_id" => c.cassette_id,
            "run_id" => c.run_id,
            "name" => c.name,
            "span_count" => length(c.snapshot),
            "recorded_at" => DateTime.to_iso8601(c.recorded_at)
          }
        end)
    }

    put_json_resp(conn, 200, body)
  end

  post "/:cassette_id/replay" do
    params = conn.body_params || %{}
    opts = build_replay_opts(params)

    case Cassettes.replay(cassette_id, opts) do
      {:ok, result} ->
        body = %{
          "run_id" => result.run_id,
          "span_count" => result.span_count,
          "hash_valid" => result.hash_valid,
          "diff" => result.diff
        }

        put_json_resp(conn, 200, body)

      {:error, :not_found} ->
        put_json_resp(conn, 404, %{"error" => "cassette not found"})

      {:error, :timeout} ->
        put_json_resp(conn, 408, %{"error" => "replay timed out waiting for ledger flush"})

      {:error, reason} ->
        put_json_resp(conn, 500, %{"error" => inspect(reason)})
    end
  end

  get "/:cassette_id" do
    case Cassettes.get(cassette_id) do
      {:ok, cassette} ->
        body = %{
          "cassette_id" => cassette.cassette_id,
          "run_id" => cassette.run_id,
          "name" => cassette.name,
          "span_count" => length(cassette.snapshot),
          "recorded_at" => DateTime.to_iso8601(cassette.recorded_at),
          "spans" => cassette.snapshot
        }

        put_json_resp(conn, 200, body)

      {:error, :not_found} ->
        put_json_resp(conn, 404, %{"error" => "cassette not found"})
    end
  end

  match _ do
    put_json_resp(conn, 404, %{"error" => "not found"})
  end

  defp build_replay_opts(params) do
    []
    |> maybe_put(:run_id, params["run_id"])
    |> maybe_put(:timeout, params["timeout_ms"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
