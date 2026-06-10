defmodule NatureWhistle.Notifier.Console do
  @moduledoc """
  Logs alerts to the console using `Logger.warning`.

  This notifier is always available and does not require any configuration.
  It is used as the default when no `:notifiers` entry is provided.

  ## Configuration

  To use the console notifier explicitly, add to your `config/config.exs`:

      config :nature_whistle, notifiers: [
        console: []   # options are ignored
      ]

  Alerts appear as warning‑level log messages:

      [warning] [NatureWhistle] 🚨 High memory: 1907 MB
  """

  @behaviour NatureWhistle.Notifier.Behaviour

  require Logger

  @impl true
  def deliver(message, metadata, _config) do
    Logger.warning("[NatureWhistle] #{message}")

    if metadata != %{} do
      Logger.debug("Alert metadata: #{inspect(metadata)}")
    end

    {:ok, :logged}
  end
end
