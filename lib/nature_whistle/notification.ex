defmodule NatureWhistle.Notification do
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
