defmodule NatureWhistle.Notifier.Dispatcher do
  @moduledoc """
  Dispatches alerts to the configured notifier using ETS-stored config.
  """

  @notifiers_table :nature_whistle_notifiers

  @notifier_modules %{
    slack: NatureWhistle.Notifier.Slack,
    teams: NatureWhistle.Notifier.Teams,
    webhook: NatureWhistle.Notifier.Webhook,
    console: NatureWhistle.Notifier.Console
  }

  def deliver(notifier_name, message, metadata) do
    with {:ok, config} <- fetch_config(notifier_name),
         {:ok, module} <- fetch_module(notifier_name) do
      module.deliver(message, metadata, config)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_config(notifier_name) do
    case :ets.lookup(@notifiers_table, notifier_name) do
      [{^notifier_name, config}] -> {:ok, config}
      [] -> {:error, "No configuration for notifier #{inspect(notifier_name)}"}
    end
  end

  defp fetch_module(notifier_name) do
    case Map.fetch(@notifier_modules, notifier_name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "Unknown notifier type: #{inspect(notifier_name)}"}
    end
  end
end
