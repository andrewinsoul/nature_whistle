defmodule NatureWhistle.EventHandler do
  @moduledoc """
  Telemetry event handler for NatureWhistle.
  """

  @alerts_table :nature_whistle_alerts
  @cooldown_table :nature_whistle_cooldown

  @doc """
  Callback invoked by :telemetry when a matching event occurs.
  """
  def handle_event(event, measurements, metadata, _config) do
    case :ets.lookup(@alerts_table, event) do
      [{^event, alerts}] ->
        value = extract_value(measurements)
        Enum.each(alerts, &check_alert(&1, value, metadata))

      [] ->
        :ok
    end
  end

  defp extract_value(measurements) do
    cond do
      is_map(measurements) and map_size(measurements) > 0 ->
        # Try common keys: :value, :total, or the first value in the map
        measurements[:value] || measurements[:total] ||
          measurements |> Map.values() |> List.first()

      true ->
        measurements
    end
  end

  defp check_alert(alert, value, metadata) do
    if value >= alert.threshold do
      if cooldown_allowed?(alert) do
        record_cooldown(alert)
        send_alert(alert, value, metadata)
      end
    end
  end

  defp cooldown_allowed?(alert) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cooldown_table, alert.id) do
      [{_id, last_trigger}] ->
        now - last_trigger >= alert.cooldown_ms

      [] ->
        true
    end
  end

  defp record_cooldown(alert) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@cooldown_table, {alert.id, now})
  end

  defp send_alert(alert, value, metadata) do
    # Interpolate %{value} in the message
    message = String.replace(alert.message, "%{value}", to_string(value))

    # Fetch notifier config
    notifier_name = alert.notifier

    case :ets.lookup(:nature_whistle_notifiers, notifier_name) do
      [{^notifier_name, notifier_config}] ->
        dispatch_to_notifier(notifier_name, message, metadata, notifier_config)

      [] ->
        IO.warn("No configuration found for notifier #{inspect(notifier_name)}")
    end
  end

  defp dispatch_to_notifier(:slack, message, metadata, config) do
    NatureWhistle.Notifier.Slack.deliver(message, metadata, config)
  end

  defp dispatch_to_notifier(:teams, message, metadata, config) do
    NatureWhistle.Notifier.Teams.deliver(message, metadata, config)
  end

  defp dispatch_to_notifier(:webhook, message, metadata, config) do
    NatureWhistle.Notifier.Webhook.deliver(message, metadata, config)
  end

  defp dispatch_to_notifier(other, _message, _metadata, _config) do
    IO.warn("Unsupported notifier: #{inspect(other)}")
  end
end
