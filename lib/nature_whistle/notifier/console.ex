defmodule NatureWhistle.Notifier.Console do
  @moduledoc """
  Console delivery backend.

  This notifier formats the final message as a warning-level log entry and
  emits telemetry metadata at debug level when metadata is present. It is the
  lowest-friction delivery option and requires no external network access.

  The module is useful in development, during local debugging, or as a safe
  fallback when no remote delivery profile is configured.
  """

  @behaviour NatureWhistle.Notifier.Behaviour

  require Logger

  @impl true
  @doc """
  Logs the message to the local application log.

  The message is emitted with `Logger.warning/1` so it stands out in a typical
  production log stream. If `metadata` is not empty, a second debug line is
  emitted containing the raw metadata map.
  """
  def deliver(message, metadata, _config) do
    Logger.warning("[NatureWhistle] #{message}")

    if metadata != %{} do
      Logger.debug("Alert metadata: #{inspect(metadata)}")
    end

    {:ok, :logged}
  end
end
