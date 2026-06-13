defmodule SpanChain.Ingestion.OtlpTranslator do
  @moduledoc """
  Translates OTLP/HTTP JSON (`ResourceSpans`) into the internal ingest format.

  The translator is a dumb adapter at the HTTP boundary — it knows nothing about the
  hash chain, the Broadway pipeline, or the DB. Hexagonal architecture (Port & Adapter):
  the downstream `SessionGenServer.ingest_spans/2` accepts our normalized
  shape the same way as spans from `/ingest`.

  ## Mapping

  - `resource.attributes["service.instance.id"]` → internal `run_id`
    (missing → `{:error, :missing_run_id}`)
  - `traceId` / `spanId` / `parentSpanId` — hex string passthrough
  - `startTimeUnixNano` / `endTimeUnixNano` (string ns) → ISO 8601
    (microsecond precision; `DateTime` cannot handle nanoseconds)
  - OTLP `KeyValue` attributes → flat `%{key => value}` map
    (`stringValue`, `intValue`, `boolValue`, `doubleValue` native; `arrayValue`/`kvlistValue` JSON-stringified — GF-974)
  - Unknown OTLP fields (`kind`, `status`, `events`, `links`, ...) silently ignored — L3 scope

  ## Example input

      %{
        "resourceSpans" => [%{
          "resource" => %{"attributes" => [
            %{"key" => "service.instance.id", "value" => %{"stringValue" => "run-123"}}
          ]},
          "scopeSpans" => [%{"spans" => [
            %{"traceId" => "abc...", "spanId" => "def...", "name" => "llm_call",
              "startTimeUnixNano" => "1716000000000000000",
              "endTimeUnixNano" => "1716000001000000000",
              "attributes" => []}
          ]}]
        }]
      }
  """

  @type span_map :: %{required(String.t()) => term()}

  @spec translate(map()) ::
          {:ok, [{String.t(), String.t() | nil, [span_map()]}]} | {:error, atom()}
  def translate(%{"resourceSpans" => resource_spans}) when is_list(resource_spans) do
    reduce_resources(resource_spans, [])
  end

  def translate(_), do: {:ok, []}

  # --------------------------------------------------------------------------
  # Private — reduce + grouping
  # --------------------------------------------------------------------------

  defp reduce_resources([], acc), do: {:ok, Enum.reverse(acc)}

  defp reduce_resources([resource | rest], acc) do
    with {:ok, run_id} <- extract_run_id(resource["resource"]) do
      eval_id = extract_eval_id(resource["resource"])
      spans = extract_spans(resource["scopeSpans"])
      reduce_resources(rest, [{run_id, eval_id, spans} | acc])
    end
  end

  defp extract_run_id(%{"attributes" => attrs}) when is_list(attrs) do
    case find_string_attr(attrs, "service.instance.id") do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :missing_run_id}
    end
  end

  defp extract_run_id(_), do: {:error, :missing_run_id}

  # GF-706: optional eval_id — `nil` if missing (NOT an error, no impact
  # on the ingest flow). The backend passively associates the run with the eval in SGS init.
  defp extract_eval_id(%{"attributes" => attrs}) when is_list(attrs) do
    case find_string_attr(attrs, "gf.eval_id") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp extract_eval_id(_), do: nil

  defp find_string_attr(attrs, key) do
    case Enum.find(attrs, fn a -> a["key"] == key end) do
      %{"value" => %{"stringValue" => v}} -> v
      _ -> nil
    end
  end

  defp extract_spans(nil), do: []

  defp extract_spans(scope_spans) when is_list(scope_spans) do
    Enum.flat_map(scope_spans, fn scope ->
      scope
      |> Map.get("spans", [])
      |> Enum.map(&translate_span/1)
    end)
  end

  defp translate_span(span) do
    %{
      "trace_id" => span["traceId"],
      "span_id" => span["spanId"],
      "parent_span_id" => span["parentSpanId"],
      "name" => span["name"],
      "started_at" => nano_to_iso8601(span["startTimeUnixNano"]),
      "ended_at" => nano_to_iso8601(span["endTimeUnixNano"]),
      "attributes" => translate_attributes(span["attributes"] || [])
    }
  end

  # --------------------------------------------------------------------------
  # Private — value coercion
  # --------------------------------------------------------------------------

  defp nano_to_iso8601(nil), do: nil

  defp nano_to_iso8601(nano_string) when is_binary(nano_string) do
    nano_string
    |> String.to_integer()
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.to_iso8601()
  rescue
    # Graceful degradation: an invalid timestamp doesn't bring down the whole request;
    # the span is accepted with `nil` started_at/ended_at.
    _ -> nil
  end

  defp nano_to_iso8601(_), do: nil

  defp translate_attributes(attrs) when is_list(attrs) do
    attrs
    |> Enum.reduce(%{}, fn
      %{"key" => k, "value" => %{"stringValue" => v}}, acc when is_binary(k) ->
        Map.put(acc, k, v)

      %{"key" => k, "value" => %{"intValue" => v}}, acc when is_binary(k) ->
        Map.put(acc, k, v)

      %{"key" => k, "value" => %{"boolValue" => v}}, acc when is_binary(k) ->
        Map.put(acc, k, v)

      %{"key" => k, "value" => %{"doubleValue" => v}}, acc
      when is_binary(k) and is_number(v) ->
        Map.put(acc, k, v)

      %{"key" => k, "value" => %{"arrayValue" => arr}}, acc when is_binary(k) ->
        Map.put(acc, k, stringify_complex(arr))

      %{"key" => k, "value" => %{"kvlistValue" => kv}}, acc when is_binary(k) ->
        Map.put(acc, k, stringify_complex(kv))

      _, acc ->
        acc
    end)
  end

  defp translate_attributes(_), do: %{}

  defp stringify_complex(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end
end
