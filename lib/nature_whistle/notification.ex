defmodule NatureWhistle.Notification do
  @moduledoc """
  Message formatting and asynchronous delivery orchestration.

  `NatureWhistle.EventHandler` decides *when* a notification should happen.
  This module decides *how* the notification is formatted and *which delivery
  profiles* should receive it.

  The dispatch path works in three stages:

  1. choose the alert message or calm message template
  2. format the current value for human-friendly display
  3. queue delivery tasks for the matching notifier profiles

  The actual HTTP or console delivery logic lives in the notifier modules under
  `NatureWhistle.Notifier.*`.
  """

  require Logger

  defp format_value(%{formatter: formatter}, value) when is_function(formatter, 1) do
    try do
      formatter.(value)
    rescue
      e ->
        Logger.error(
          "NatureWhistle custom formatter failed: #{inspect(e)}. Falling back to string cast."
        )

        to_string(value)
    end
  end

  defp format_value(%{event: [:vm, :memory, :total]}, value) do
    mb = div(value, 1_048_576)
    "#{mb} MB"
  end

  defp format_value(_event, value) do
    to_string(value)
  end

  defp dispatch_to_notifier(:slack, message, metadata, config) do
    case NatureWhistle.Notifier.Slack.deliver(message, metadata, config) do
      {:ok, :sent} ->
        :ok

      {:error, :max_attempts_exceeded} ->
        Logger.error(
          "🚨 Notification completely failed after maximum retry attempts for slack service"
        )

        {:error, :max_attempts_exceeded}
    end
  end

  defp dispatch_to_notifier(:teams, message, metadata, config) do
    case NatureWhistle.Notifier.Teams.deliver(message, metadata, config) do
      {:ok, :sent} ->
        :ok

      {:error, :max_attempts_exceeded} ->
        Logger.error(
          "🚨 Notification completely failed after maximum retry attempts for teams service"
        )

        {:error, :max_attempts_exceeded}
    end
  end

  defp dispatch_to_notifier(:webhook, message, metadata, config) do
    case NatureWhistle.Notifier.Webhook.deliver(message, metadata, config) do
      {:ok, :sent} ->
        :ok

      {:error, :max_attempts_exceeded} ->
        Logger.error(
          "🚨 Notification completely failed after maximum retry attempts for webhook service"
        )

        {:error, :max_attempts_exceeded}
    end
  end

  defp dispatch_to_notifier(:console, message, metadata, _config) do
    NatureWhistle.Notifier.Console.deliver(message, metadata, %{})
  end

  defp dispatch_to_notifier(other, _message, _metadata, _config) do
    Logger.warning("Unsupported notifier: #{inspect(other)}")
  end

  defp default_notifiers do
    [
      %{
        name: :console,
        service: :console,
        config: nil
      }
    ]
  end

  @doc """
  Formats and dispatches a notification for the given alert.

  Parameters:

  - `alert` - the normalized alert map loaded from ETS
  - `value` - the current measurement value that triggered the notification
  - `metadata` - telemetry metadata forwarded to the notifier implementation
  - `type` - either `:alert` or `:calm`

  The function:

  - selects `alert_message` for `:alert` or `calm_message` for `:calm`
  - formats the value using the alert's `formatter`, if one exists
  - replaces `%{value}` in the message template
  - loads `:notifiers_config` from application env, falling back to console
  - matches alert profile names from `alert.notifiers` against the global
    notifier profiles by `name`
  - spawns an asynchronous task for each matching built-in notifier service

  If no notifier profile matches, nothing is dispatched and a warning is logged.
  """
  def send_notification(alert, value, metadata, type) do
    message_template = if type == :alert, do: alert.alert_message, else: alert.calm_message
    formatted_value = format_value(alert, value)
    message = String.replace(message_template, "%{value}", formatted_value)

    notifiers_config =
      Application.get_env(:nature_whistle, :notifiers_config, default_notifiers())

    alert_notifiers = Map.get(alert, :notifiers, [:console])

    allowed_targets =
      Enum.flat_map(alert_notifiers, fn notifier_name ->
        case Enum.find(notifiers_config, fn config ->
               is_map(config) and Map.get(config, :name) == notifier_name
             end) do
          %{service: service} ->
            [service]

          nil ->
            Logger.warning("Notifier config not found for #{inspect(notifier_name)}")
            []
        end
      end)

    notifiers_config
    |> Enum.filter(fn config ->
      is_map(config) and Map.get(config, :service) in allowed_targets
    end)
    |> Enum.each(fn %{service: notifier_name, config: notifier_config} ->
      Task.Supervisor.start_child(
        NatureWhistle.TaskSupervisor,
        fn ->
          dispatch_to_notifier(notifier_name, message, metadata, notifier_config)
        end
      )
    end)
  end
end
