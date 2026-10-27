defmodule NatureWhistle.Notifier.Console do
  @moduledoc """
  Console delivery backend.

  This notifier formats the final message as a warning-level log entry. Raw
  telemetry metadata is not logged by default. Set `:include_metadata` to
  `true` for opt-in diagnostics; sensitive fields are redacted before logging.
  It is the lowest-friction delivery option and requires no external network
  access.

  The module is useful in development, during local debugging, or as a safe
  fallback when no remote delivery profile is configured.
  """

  @behaviour NatureWhistle.Notifier.Behaviour

  require Logger

  @impl true
  @doc """
  Logs the message to the local application log.

  The message is emitted with `Logger.warning/1` so it stands out in a typical
  production log stream. A second debug line is emitted only when
  `:include_metadata` is enabled, and sensitive metadata fields are redacted.
  """
  def deliver(message, metadata, config) do
    Logger.warning("[NatureWhistle] #{message}")

    config =
      cond do
        is_list(config) -> Map.new(config)
        is_map(config) -> config
        true -> %{}
      end

    if Map.get(config, :include_metadata, false) and metadata != %{} do
      redacted_metadata = NatureWhistle.Notifier.Security.redact_metadata(metadata)
      Logger.debug("Alert metadata: #{inspect(redacted_metadata)}")
    end

    {:ok, :logged}
  end
end
