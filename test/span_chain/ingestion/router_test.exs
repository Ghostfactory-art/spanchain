# GF-849: stub session registrovaný pod run_id Registry klíčem. ensure_session ho najde
# přes Registry.lookup (reuse path, nespawnuje reálný SGS), ingest_spans na něj zavolá a
# dostane {:error, …} — deterministická injektáž chyby bez sahání na SessionGenServer.
defmodule SpanChain.Ingestion.ErrorStubSession do
  @moduledoc false
  use GenServer
  alias SpanChain.Ingestion.SessionGenServer

  def start_link(run_id),
    do: GenServer.start_link(__MODULE__, :ok, name: SessionGenServer.via_tuple(run_id))

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:ingest_spans, _spans, _opts}, _from, state),
    do: {:reply, {:error, :stub_ingest_error}, state}
end

defmodule SpanChain.Ingestion.RouterTest do
  use SpanChain.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias SpanChain.Cassettes
  alias SpanChain.Ingestion.{ErrorStubSession, Router, SessionGenServer, SessionSupervisor}

  @opts Router.init([])

  @valid_token "test-secret"

  defp post_json(body, opts \\ []) do
    token = Keyword.get(opts, :token, @valid_token)

    conn =
      :post
      |> conn("/ingest", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn =
      case token do
        :none -> conn
        {:raw, raw} -> put_req_header(conn, "authorization", raw)
        binary when is_binary(binary) -> put_req_header(conn, "authorization", "Bearer #{binary}")
      end

    Router.call(conn, @opts)
  end

  # GF-649: OTLP/HTTP JSON endpoint helper.
  defp post_otlp(body, opts \\ []) do
    token = Keyword.get(opts, :token, @valid_token)

    conn =
      :post
      |> conn("/v1/traces", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn =
      case token do
        :none -> conn
        binary when is_binary(binary) -> put_req_header(conn, "authorization", "Bearer #{binary}")
      end

    Router.call(conn, @opts)
  end

  defp otlp_body(run_id, span_overrides \\ %{}) do
    base_span = %{
      "traceId" => "abc123def456",
      "spanId" => "0123456789ab",
      "name" => "llm_call",
      "startTimeUnixNano" => "1716000000000000000",
      "endTimeUnixNano" => "1716000001000000000",
      "attributes" => []
    }

    %{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.instance.id", "value" => %{"stringValue" => run_id}}
            ]
          },
          "scopeSpans" => [%{"spans" => [Map.merge(base_span, span_overrides)]}]
        }
      ]
    }
  end

  test "POST /ingest with valid payload returns 202" do
    body = %{
      "run_id" => "router-test-1",
      "spans" => [
        %{
          "span_id" => "s1",
          "name" => "llm_call",
          "started_at" => "2026-05-15T10:00:00Z",
          "ended_at" => "2026-05-15T10:00:01Z",
          "attributes" => %{}
        }
      ]
    }

    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:router-test-1")
    conn = post_json(body)
    assert conn.status == 202
    assert {:ok, %{"accepted" => 1, "run_id" => "router-test-1"}} = Jason.decode(conn.resp_body)

    # GF-703: post-commit PubSub broadcast firi AŽ PO Repo.transaction return
    # → Broadway uvolnil connection. Telemetry [:gf, :ledger, :batch_insert, :stop]
    # firi UVNITR transakce → race s commit → Exqlite ConnectionError "owner exited".
    assert_receive {:spans_flushed, "router-test-1"}, 5_000
  end

  test "POST /ingest with missing run_id returns 400" do
    conn = post_json(%{"spans" => [%{"span_id" => "s1"}]})
    assert conn.status == 400
  end

  test "POST /ingest with empty spans returns 400" do
    conn = post_json(%{"run_id" => "r1", "spans" => []})
    assert conn.status == 400
  end

  test "POST /ingest with non-list spans returns 400" do
    conn = post_json(%{"run_id" => "r1", "spans" => "not-a-list"})
    assert conn.status == 400
  end

  test "GET /health returns 200" do
    conn = conn(:get, "/health") |> Router.call(@opts)
    assert conn.status == 200
  end

  test "emits [:gf, :ingest, :request, :stop] telemetry" do
    handler_id = "ingest-req-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:gf, :ingest, :request, :stop],
      fn _e, m, md, _ -> send(test_pid, {:req_stop, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    body = %{
      "run_id" => "telem-test",
      "spans" => [%{"span_id" => "s1", "name" => "x"}]
    }

    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:telem-test")
    _conn = post_json(body)

    assert_receive {:req_stop, _m, %{run_id: "telem-test", status: 202}}, 1_000
    # GF-703: post-commit broadcast (viz "POST /ingest" test komentar).
    assert_receive {:spans_flushed, "telem-test"}, 5_000
  end

  describe "input validation (GF-767)" do
    # ValidationPlug odmítne malformed run_id na /ingest boundary (před validate/1).
    # Minimální spans → jediný failující faktor je run_id.
    @bad_id_spans [%{"span_id" => "s1", "name" => "llm_call"}]

    test "path traversal run_id → 400 invalid_id_format" do
      conn = post_json(%{"run_id" => "../../etc/passwd", "spans" => @bad_id_spans})
      assert conn.status == 400
      assert {:ok, %{"error" => "invalid_id_format"}} = Jason.decode(conn.resp_body)
    end

    test "SQL injection run_id → 400" do
      conn =
        post_json(%{"run_id" => "'; DROP TABLE ledger_entries; --", "spans" => @bad_id_spans})

      assert conn.status == 400
      assert {:ok, %{"error" => "invalid_id_format"}} = Jason.decode(conn.resp_body)
    end

    test "run_id delší než 128 znaků → 400" do
      conn = post_json(%{"run_id" => String.duplicate("a", 129), "spans" => @bad_id_spans})
      assert conn.status == 400
    end

    test "prázdný run_id → 400" do
      conn = post_json(%{"run_id" => "", "spans" => @bad_id_spans})
      assert conn.status == 400
    end

    test "validní slug run_id → 202" do
      run_id = "my-agent_run-001"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")

      conn =
        post_json(%{"run_id" => run_id, "spans" => [%{"span_id" => "s1", "name" => "llm_call"}]})

      assert conn.status == 202

      assert_receive {:spans_flushed, ^run_id}, 5_000
    end

    test "UUID formát run_id → 202" do
      run_id = "550e8400-e29b-41d4-a716-446655440000"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")

      conn =
        post_json(%{"run_id" => run_id, "spans" => [%{"span_id" => "s1", "name" => "llm_call"}]})

      assert conn.status == 202

      assert_receive {:spans_flushed, ^run_id}, 5_000
    end
  end

  describe "rate limiting (GF-766)" do
    setup do
      Application.put_env(:span_chain, :rate_limit_enabled, true)
      Application.put_env(:span_chain, :rate_limit_count, 2)
      # Sdílený token bucket (klíč = Bearer token, period 60s) — vyčisti mezi testy.
      PlugAttack.Storage.Ets.clean(SpanChain.Ingestion.RateLimiter)

      on_exit(fn ->
        Application.put_env(:span_chain, :rate_limit_enabled, false)
        Application.put_env(:span_chain, :rate_limit_count, 1_000)
      end)

      :ok
    end

    test "throttle per API key — 3. request nad limit → 429 + Retry-After" do
      run_id = "rate-limit-test"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      body = %{"run_id" => run_id, "spans" => [%{"span_id" => "s1", "name" => "llm_call"}]}

      # Request 1 a 2 pod limitem (limit: 2) → 202; čekej na Broadway flush
      # (CLAUDE.md: post-commit PubSub broadcast, jinak Exqlite "owner exited").
      assert post_json(body).status == 202
      assert_receive {:spans_flushed, ^run_id}, 5_000

      assert post_json(body).status == 202
      assert_receive {:spans_flushed, ^run_id}, 5_000

      # Request 3 nad limit → 429 + halt() PŘED Plug.Parsers/match (data do SGS nedorazí).
      conn = post_json(body)
      assert conn.status == 429
      assert {:ok, %{"error" => "rate_limit_exceeded"}} = Jason.decode(conn.resp_body)
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    # GF-785: /health musí být exempt i s Bearer tokenem nad limit. Token-bearing
    # (ne tokenless) — tokenless /health by prošel i bez fixu přes `_ -> allow(true)`.
    test "GET /health je exempt z throttle — i s tokenem nad limit → vždy 200 (GF-785)" do
      # count: 2 (setup). Bez exempt pravidla by 3. token-bearing /health dostal 429.
      for _ <- 1..(2 + 2) do
        conn =
          conn(:get, "/health")
          |> put_req_header("authorization", "Bearer #{@valid_token}")
          |> Router.call(@opts)

        assert conn.status == 200
      end
    end

    test "/ingest stále throttluje + /health exempt i po vyčerpání bucketu (GF-785 regrese)" do
      run_id = "gf785-regress"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
      body = %{"run_id" => run_id, "spans" => [%{"span_id" => "s1", "name" => "llm_call"}]}

      # 2 pod limitem → 202 (čekej na Broadway flush), 3. nad limit → 429 (regrese).
      assert post_json(body).status == 202
      assert_receive {:spans_flushed, ^run_id}, 5_000
      assert post_json(body).status == 202
      assert_receive {:spans_flushed, ^run_id}, 5_000
      assert post_json(body).status == 429

      # Stejný token má vyčerpaný bucket, ale /health je exempt → 200 (nezávisle na bucketu).
      health =
        conn(:get, "/health")
        |> put_req_header("authorization", "Bearer #{@valid_token}")
        |> Router.call(@opts)

      assert health.status == 200
    end
  end

  describe "POST /v1/traces (GF-649)" do
    test "valid OTLP body returns 200 + partialSuccess JSON" do
      run_id = "otlp-test-1"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")

      conn = post_otlp(otlp_body(run_id))

      assert conn.status == 200

      assert {:ok, %{"partialSuccess" => %{"rejectedSpans" => 0}}} =
               Jason.decode(conn.resp_body)

      assert_receive {:spans_flushed, ^run_id}, 5_000
    end

    # GF-774: run_id validace na /v1/traces (obchází path-scoped ValidationPlug).
    # run_id jde přes resource.attributes["service.instance.id"] (viz otlp_body/2).
    test "POST /v1/traces rejects path traversal run_id" do
      conn = post_otlp(otlp_body("../../etc/passwd"))
      assert conn.status == 400
      assert {:ok, %{"error" => "invalid_id_format"}} = Jason.decode(conn.resp_body)
    end

    test "POST /v1/traces rejects over-long run_id" do
      conn = post_otlp(otlp_body(String.duplicate("a", 129)))
      assert conn.status == 400
      assert {:ok, %{"error" => "invalid_id_format"}} = Jason.decode(conn.resp_body)
    end

    test "POST /v1/traces rejects run_id with invalid chars" do
      conn = post_otlp(otlp_body("bad id!"))
      assert conn.status == 400
      assert {:ok, %{"error" => "invalid_id_format"}} = Jason.decode(conn.resp_body)
    end

    test "POST /v1/traces accepts valid run_id (regression)" do
      run_id = "valid-run-123"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")

      conn = post_otlp(otlp_body(run_id))

      assert conn.status == 200
      assert {:ok, %{"partialSuccess" => %{"rejectedSpans" => 0}}} = Jason.decode(conn.resp_body)
      assert_receive {:spans_flushed, ^run_id}, 5_000
    end

    test "missing service.instance.id returns 400" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.name", "value" => %{"stringValue" => "no-instance"}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "x"}]}]
          }
        ]
      }

      conn = post_otlp(body)
      assert conn.status == 400
      assert {:ok, %{"error" => err}} = Jason.decode(conn.resp_body)
      assert err =~ "service.instance.id"
    end

    test "without Bearer token returns 401 (AuthPlug applies)" do
      conn = post_otlp(otlp_body("auth-check"), token: :none)
      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "multiple resourceSpans group by run_id — both flush via Pipeline" do
      run_a = "otlp-multi-a"
      run_b = "otlp-multi-b"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_a}")
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_b}")

      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => run_a}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "a"}]}]
          },
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => run_b}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "b"}]}]
          }
        ]
      }

      conn = post_otlp(body)
      assert conn.status == 200

      assert_receive {:spans_flushed, ^run_a}, 5_000
      assert_receive {:spans_flushed, ^run_b}, 5_000
    end
  end

  describe "POST /v1/traces error resilience (GF-849)" do
    test "ingest {:error} → 200 (ne 500) + rejectedSpans + log, ne MatchError" do
      run_id = "otlp-err-1"
      start_supervised!(%{id: :otlp_err_stub, start: {ErrorStubSession, :start_link, [run_id]}})

      log =
        capture_log(fn ->
          conn = post_otlp(otlp_body(run_id))

          # Jádro fixu: bare match by hodil MatchError → 500. with/else → 200.
          assert conn.status == 200

          assert {:ok, %{"partialSuccess" => %{"rejectedSpans" => 1}}} =
                   Jason.decode(conn.resp_body)
        end)

      assert log =~ "run_id=#{run_id}"
      assert log =~ "stub_ingest_error"
    end

    test "chybná group nezahodí zbývající — dobrá projde, chybná je rejected" do
      run_ok = "otlp-mix-ok"
      run_bad = "otlp-mix-bad"
      Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_ok}")
      start_supervised!(%{id: :otlp_mix_stub, start: {ErrorStubSession, :start_link, [run_bad]}})

      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => run_ok}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "ok"}]}]
          },
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => run_bad}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "bad"}]}]
          }
        ]
      }

      conn = post_otlp(body)

      assert conn.status == 200
      assert {:ok, %{"partialSuccess" => %{"rejectedSpans" => 1}}} = Jason.decode(conn.resp_body)

      # Dobrá group se ingestla a flushla navzdory chybné (žádné tiché zahození).
      assert_receive {:spans_flushed, ^run_ok}, 5_000
    end
  end

  describe "AuthPlug (GF-646)" do
    @valid_body %{
      "run_id" => "auth-test",
      "spans" => [%{"span_id" => "s1", "name" => "x"}]
    }

    test "POST /ingest bez authorization hlavičky → 401" do
      conn = post_json(@valid_body, token: :none)
      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "POST /ingest s nesprávným tokenem → 401" do
      conn = post_json(@valid_body, token: "wrong-token")
      assert conn.status == 401
    end

    test "POST /ingest s authorization bez Bearer prefixu → 401" do
      conn = post_json(@valid_body, token: {:raw, "test-secret"})
      assert conn.status == 401
    end

    test "GET /health je volný — bez authorization → 200" do
      conn = conn(:get, "/health") |> Router.call(@opts)
      assert conn.status == 200
    end
  end

  describe "POST /cassettes/record (GF-712)" do
    test "valid body returns 201 + cassette JSON" do
      run_id = "cas-rt-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      cid = "cas-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      seed_single_span_run(run_id)

      conn =
        post_router(:post, "/cassettes/record", %{
          "run_id" => run_id,
          "cassette_id" => cid,
          "name" => "router-rec"
        })

      assert conn.status == 201
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["cassette_id"] == cid
      assert body["run_id"] == run_id
      assert body["span_count"] == 1
      assert is_binary(body["recorded_at"])
    end

    test "missing cassette_id returns 400" do
      conn = post_router(:post, "/cassettes/record", %{"run_id" => "x"})
      assert conn.status == 400
      assert {:ok, %{"error" => err}} = Jason.decode(conn.resp_body)
      assert err =~ "cassette_id"
    end

    test "unknown run_id returns 404" do
      conn =
        post_router(:post, "/cassettes/record", %{
          "run_id" =>
            "does-not-exist-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
          "cassette_id" => "cid-#{System.unique_integer([:positive])}"
        })

      assert conn.status == 404
    end
  end

  describe "GET /cassettes/:id (GF-712)" do
    test "existing cassette returns 200 with spans" do
      run_id = "cas-get-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      cid = "cas-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      seed_single_span_run(run_id)
      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      conn = post_router(:get, "/cassettes/#{cid}")
      assert conn.status == 200
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["cassette_id"] == cid
      assert is_list(body["spans"])
      assert length(body["spans"]) == 1
    end

    test "missing cassette returns 404" do
      conn = post_router(:get, "/cassettes/does-not-exist-xyz")
      assert conn.status == 404
    end
  end

  describe "POST /cassettes/:id/replay (GF-712)" do
    test "identical replay returns 200 with hash_valid:true and empty diff" do
      run_id = "cas-rp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      cid = "cas-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      seed_single_span_run(run_id)
      {:ok, _} = Cassettes.record(run_id, cassette_id: cid)

      conn = post_router(:post, "/cassettes/#{cid}/replay", %{})
      assert conn.status == 200
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["hash_valid"] == true
      assert body["diff"] == []
      assert body["span_count"] == 1
      assert is_binary(body["run_id"])
    end
  end

  # ---------------------------------------------------------------------------
  # Helper — generic router call used by /cassettes tests.
  # ---------------------------------------------------------------------------

  # GF-712: čekej na post-commit PubSub broadcast (GF-703), NE na telemetry
  # `[:gf, :ledger, :batch_insert, :stop]` — ten firi UVNITR Repo.transakce
  # (pred commitem) → test exit pak race-uje s Broadway commitem → Exqlite
  # ConnectionError "owner exited" v logu. `{:spans_flushed, run_id}` firi
  # AŽ PO `Repo.transaction` returnu (tj. po commitu i release connection).
  defp seed_single_span_run(run_id) do
    Phoenix.PubSub.subscribe(SpanChain.PubSub, "run:#{run_id}")
    {:ok, _pid} = SessionSupervisor.ensure_session(run_id)

    {:ok, _n} =
      SessionGenServer.ingest_spans(run_id, [
        %{
          "span_id" => "seed-#{run_id}",
          "name" => "seeded",
          "started_at" => "2026-05-17T10:00:00.000Z",
          "ended_at" => "2026-05-17T10:00:01.000Z",
          "attributes" => %{}
        }
      ])

    assert_receive {:spans_flushed, ^run_id}, 5_000
    Phoenix.PubSub.unsubscribe(SpanChain.PubSub, "run:#{run_id}")
    :ok
  end

  defp post_router(method, path, body \\ nil, opts \\ []) do
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
end
