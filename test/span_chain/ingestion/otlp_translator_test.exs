defmodule SpanChain.Ingestion.OtlpTranslatorTest do
  @moduledoc """
  Unit tests for the OTLP/HTTP JSON translator (GF-649). Pure functions, no DB,
  no GenServer — the translator is an adapter at the HTTP boundary.
  """

  use ExUnit.Case, async: true

  alias SpanChain.Ingestion.OtlpTranslator

  defp valid_otlp_request(run_id, span_overrides \\ %{}) do
    base_span = %{
      "traceId" => "abc123def456",
      "spanId" => "0123456789ab",
      "parentSpanId" => nil,
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
          "scopeSpans" => [
            %{"spans" => [Map.merge(base_span, span_overrides)]}
          ]
        }
      ]
    }
  end

  describe "translate/1" do
    test "happy path — valid ResourceSpans returns grouped run_id + nil eval_id + span list" do
      body = valid_otlp_request("run-x")
      # GF-706: 3-tuple {run_id, eval_id_or_nil, spans}. eval_id nil when gf.eval_id missing.
      assert {:ok, [{"run-x", nil, [span]}]} = OtlpTranslator.translate(body)

      assert span["trace_id"] == "abc123def456"
      assert span["span_id"] == "0123456789ab"
      assert span["parent_span_id"] == nil
      assert span["name"] == "llm_call"
      assert is_binary(span["started_at"])
      assert is_binary(span["ended_at"])
      assert span["attributes"] == %{}
    end

    test "GF-706: extract gf.eval_id from resource attributes when present" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => "run-z"}},
                %{"key" => "gf.eval_id", "value" => %{"stringValue" => "eval-abc"}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "x"}]}]
          }
        ]
      }

      assert {:ok, [{"run-z", "eval-abc", [_]}]} = OtlpTranslator.translate(body)
    end

    test "missing service.instance.id returns {:error, :missing_run_id}" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.name", "value" => %{"stringValue" => "my-agent"}}
              ]
            },
            "scopeSpans" => [%{"spans" => []}]
          }
        ]
      }

      assert OtlpTranslator.translate(body) == {:error, :missing_run_id}
    end

    test "nano timestamp parsing uses :nanosecond unit (microsecond precision in output)" do
      # 1716000000000123456 ns = 2024-05-18T02:40:00.000123 UTC (456 ns truncated).
      # If the parser used :millisecond, the number would be out of DateTime range → raise →
      # rescue → nil. The `.000123` microsecond part in the ISO8601 output PROVES the correct
      # :nanosecond unit (the truncated '456' nanoseconds are L2 acceptable).
      body = valid_otlp_request("ns-test", %{"startTimeUnixNano" => "1716000000000123456"})

      assert {:ok, [{"ns-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert span["started_at"] == "2024-05-18T02:40:00.000123Z"
    end

    test "multiple resourceSpans group by run_id" do
      body = %{
        "resourceSpans" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => "run-a"}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "span-a-1"}]}]
          },
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "service.instance.id", "value" => %{"stringValue" => "run-b"}}
              ]
            },
            "scopeSpans" => [%{"spans" => [%{"name" => "span-b-1"}, %{"name" => "span-b-2"}]}]
          }
        ]
      }

      assert {:ok, groups} = OtlpTranslator.translate(body)

      assert [
               {"run-a", nil, [%{"name" => "span-a-1"}]},
               {"run-b", nil, [%{"name" => "span-b-1"}, %{"name" => "span-b-2"}]}
             ] = groups
    end

    test "intValue, boolValue, and doubleValue attributes translate to flat map with correct types" do
      body =
        valid_otlp_request("attr-test", %{
          "attributes" => [
            %{"key" => "s", "value" => %{"stringValue" => "hello"}},
            %{"key" => "n", "value" => %{"intValue" => 42}},
            %{"key" => "b", "value" => %{"boolValue" => true}},
            %{"key" => "d", "value" => %{"doubleValue" => 3.14}}
          ]
        })

      assert {:ok, [{"attr-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert span["attributes"] == %{"s" => "hello", "n" => 42, "b" => true, "d" => 3.14}
    end

    test "GF-747: doubleValue attribute preserved as float (was silently dropped pre-fix)" do
      body =
        valid_otlp_request("double-test", %{
          "attributes" => [
            %{"key" => "cost_usd", "value" => %{"doubleValue" => 0.00096}}
          ]
        })

      assert {:ok, [{"double-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert span["attributes"] == %{"cost_usd" => 0.00096}
      assert is_float(span["attributes"]["cost_usd"])
    end

    test "GF-747: doubleValue with integer JSON value (0.0 decoded as integer) still maps" do
      # The JSON decoder may return an integer for 0.0 → the is_number guard protects against this
      body =
        valid_otlp_request("double-int", %{
          "attributes" => [
            %{"key" => "temperature", "value" => %{"doubleValue" => 0}}
          ]
        })

      assert {:ok, [{"double-int", nil, [span]}]} = OtlpTranslator.translate(body)
      assert span["attributes"]["temperature"] == 0
    end

    test "GF-974: arrayValue attribute is stringified to JSON, not dropped" do
      body =
        valid_otlp_request("arr-test", %{
          "attributes" => [
            %{
              "key" => "my_list",
              "value" => %{
                "arrayValue" => %{
                  "values" => [
                    %{"stringValue" => "a"},
                    %{"stringValue" => "b"}
                  ]
                }
              }
            }
          ]
        })

      assert {:ok, [{"arr-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert is_binary(span["attributes"]["my_list"])
      refute is_nil(span["attributes"]["my_list"])
      assert {:ok, _} = Jason.decode(span["attributes"]["my_list"])
    end

    test "GF-974: kvlistValue attribute is stringified to JSON, not dropped" do
      body =
        valid_otlp_request("kv-test", %{
          "attributes" => [
            %{
              "key" => "my_map",
              "value" => %{
                "kvlistValue" => %{
                  "values" => [
                    %{"key" => "x", "value" => %{"intValue" => 1}}
                  ]
                }
              }
            }
          ]
        })

      assert {:ok, [{"kv-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert is_binary(span["attributes"]["my_map"])
      assert {:ok, _} = Jason.decode(span["attributes"]["my_map"])
    end

    test "GF-974: nested arrayValue produces valid JSON string" do
      body =
        valid_otlp_request("nested-test", %{
          "attributes" => [
            %{
              "key" => "nested",
              "value" => %{
                "arrayValue" => %{
                  "values" => [
                    %{"arrayValue" => %{"values" => [%{"stringValue" => "deep"}]}}
                  ]
                }
              }
            }
          ]
        })

      assert {:ok, [{"nested-test", nil, [span]}]} = OtlpTranslator.translate(body)
      assert is_binary(span["attributes"]["nested"])
      assert {:ok, decoded} = Jason.decode(span["attributes"]["nested"])
      assert is_list(decoded) or is_map(decoded)
    end
  end
end
