defmodule SpanChain.Evals.RouterTest do
  @moduledoc """
  HTTP tests for the /evals sub-router (GF-706). Forwarded from the main
  `Ingestion.Router` on port 4000. AuthPlug applies automatically.
  """

  use SpanChain.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias SpanChain.{Eval, Repo, Run}
  alias SpanChain.Ingestion.Router

  @opts Router.init([])
  @valid_token "test-secret"

  defp call_router(method, path, body \\ nil, opts \\ []) do
    token = Keyword.get(opts, :token, @valid_token)

    conn =
      case {method, body} do
        {:post, b} when is_map(b) ->
          :post
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")

        {:get, _} ->
          conn(:get, path)
      end

    conn =
      case token do
        :none -> conn
        binary -> put_req_header(conn, "authorization", "Bearer #{binary}")
      end

    Router.call(conn, @opts)
  end

  defp fresh_eval_id,
    do: "eval-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp fresh_run_id,
    do: "evals-rt-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  describe "POST /evals" do
    test "valid body returns 201 + eval JSON" do
      eval_id = fresh_eval_id()
      conn = call_router(:post, "/evals", %{"eval_id" => eval_id, "name" => "LLM comparison"})

      assert conn.status == 201

      assert {:ok,
              %{
                "eval_id" => ^eval_id,
                "name" => "LLM comparison",
                "status" => "running",
                "created_at" => created_at
              }} = Jason.decode(conn.resp_body)

      assert is_binary(created_at)
    end

    test "missing eval_id returns 400" do
      conn = call_router(:post, "/evals", %{"name" => "no eval_id"})

      assert conn.status == 400
      assert {:ok, %{"error" => "eval_id is required"}} = Jason.decode(conn.resp_body)
    end

    test "no auth header returns 401" do
      conn = call_router(:post, "/evals", %{"eval_id" => "x"}, token: :none)
      assert conn.status == 401
    end
  end

  describe "GET /evals/:eval_id" do
    test "existing eval returns 200 with run_count + run_ids" do
      eval_id = fresh_eval_id()
      Repo.insert!(%Eval{eval_id: eval_id, status: "running"})

      run_a = fresh_run_id()
      run_b = fresh_run_id()
      Repo.insert!(%Run{run_id: run_a, status: "completed", eval_id: eval_id})
      Repo.insert!(%Run{run_id: run_b, status: "completed", eval_id: eval_id})

      conn = call_router(:get, "/evals/#{eval_id}")

      assert conn.status == 200

      assert {:ok,
              %{
                "eval_id" => ^eval_id,
                "status" => "running",
                "run_count" => 2,
                "run_ids" => run_ids
              }} = Jason.decode(conn.resp_body)

      assert MapSet.new(run_ids) == MapSet.new([run_a, run_b])
    end

    test "missing eval returns 404" do
      conn = call_router(:get, "/evals/does-not-exist-12345")
      assert conn.status == 404
      assert {:ok, %{"error" => "eval not found"}} = Jason.decode(conn.resp_body)
    end
  end

  describe "GET /evals/:eval_id/compare" do
    test "valid run_a + run_b returns 200 JSON diff" do
      eval_id = fresh_eval_id()
      Repo.insert!(%Eval{eval_id: eval_id, status: "running"})

      run_a = fresh_run_id()
      run_b = fresh_run_id()
      Repo.insert!(%Run{run_id: run_a, status: "completed", eval_id: eval_id})
      Repo.insert!(%Run{run_id: run_b, status: "completed", eval_id: eval_id})

      conn = call_router(:get, "/evals/#{eval_id}/compare?run_a=#{run_a}&run_b=#{run_b}")

      assert conn.status == 200

      assert {:ok, %{"summary" => summary, "differences" => diffs}} =
               Jason.decode(conn.resp_body)

      assert summary["eval_id"] == eval_id
      assert is_list(diffs)
    end

    test "missing query params returns 400" do
      eval_id = fresh_eval_id()
      Repo.insert!(%Eval{eval_id: eval_id, status: "running"})

      conn = call_router(:get, "/evals/#{eval_id}/compare")
      assert conn.status == 400
    end
  end
end
