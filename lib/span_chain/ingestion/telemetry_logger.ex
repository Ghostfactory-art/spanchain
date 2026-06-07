defmodule SpanChain.Ingestion.TelemetryLogger do
  @moduledoc "Loguje všechny `[:gf, ...]` telemetry eventy přes Logger — debug-only handler."

  require Logger

  @events [
    [:gf, :ingest, :request, :start],
    [:gf, :ingest, :request, :stop],
    [:gf, :ingest, :request, :exception],
    [:gf, :session, :spawn, :start],
    [:gf, :session, :spawn, :stop],
    [:gf, :session, :spawn, :exception],
    [:gf, :ledger, :batch_insert, :start],
    [:gf, :ledger, :batch_insert, :stop],
    [:gf, :ledger, :batch_insert, :exception],
    [:gf, :epoch, :boundary],
    [:gf, :flush, :success],
    [:gf, :flush, :dead_letter]
  ]

  @handler_id "gf-telemetry-logger"

  @doc "Připojí handler. Idempotentní — re-attach na již existující ID je no-op."
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:gf, :flush, :dead_letter] = event, measurements, metadata, _config) do
    Logger.error(
      "[telemetry] #{Enum.join(event, ".")} measurements=#{inspect(measurements)} meta=#{inspect(metadata)}"
    )
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.info(
      "[telemetry] #{Enum.join(event, ".")} measurements=#{inspect(measurements)} meta=#{inspect(metadata)}"
    )
  end
end
