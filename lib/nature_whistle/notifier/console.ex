defmodule NatureWhistle.Notifier.Console do
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
