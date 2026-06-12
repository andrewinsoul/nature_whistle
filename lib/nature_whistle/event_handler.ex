defmodule NatureWhistle.EventHandler do
  @moduledoc """
  Telemetry event handler for NatureWhistle.
  """
  require Logger

  @alerts_table :nature_whistle_alerts
  @cooldown_table :nature_whistle_cooldown
  @state_table :nature_whistle_alert_state

  @doc """
  Callback invoked by :telemetry when a matching event occurs.
  """
  def handle_event(event, measurements, metadata, _config) do
    case :ets.lookup(@alerts_table, event) do
      [{^event, alerts}] ->
        try do
          Enum.each(alerts, &check_alert(&1, measurements, metadata))
        rescue
          e -> Logger.error("NatureWhistle alert handler crashed: #{inspect(e)}")
        end

      [] ->
        :ok
    end
  end

  defp check_alert(alert, measurements, metadata) do
    value = extract_value(measurements, alert.measurement_key)

    if is_number(value) do
      current_time = System.monotonic_time(:millisecond)

      if value >= alert.threshold do
        handle_high_value(alert, value, metadata, current_time)
      else
        handle_low_value(alert, value, metadata, current_time)
      end
    end
  end

  defp handle_high_value(alert, value, metadata, current_time) do
    case get_alert_state(alert.id) do
      nil ->
        if cooldown_allowed?(alert, current_time) do
          send_notification(alert, value, metadata, :alert)
          record_cooldown(alert, current_time)
          update_alert_state(alert.id, {:firing, current_time, nil})
        end

      {:calm, _, _} ->
        if cooldown_allowed?(alert, current_time) do
          send_notification(alert, value, metadata, :alert)
          record_cooldown(alert, current_time)
          update_alert_state(alert.id, {:firing, current_time, nil})
        end

      {:firing, last_alert_time, _} ->
        if current_time - last_alert_time >= alert.cooldown_ms do
          send_notification(alert, value, metadata, :alert)
          record_cooldown(alert, current_time)
          update_alert_state(alert.id, {:firing, current_time, nil})
        end
    end
  end

  defp handle_low_value(alert, value, metadata, current_time) do
    case get_alert_state(alert.id) do
      {:firing, last_alert_time, below_since} ->
        new_below_since = below_since || current_time

        if current_time - new_below_since >= alert.resolution_ms do
          send_notification(alert, value, metadata, :calm)
          update_alert_state(alert.id, {:calm, nil, nil})
        else
          update_alert_state(alert.id, {:firing, last_alert_time, new_below_since})
        end

      _ ->
        :ok
    end
  end

  defp extract_value(measurements, measurement_key) do
    if is_map(measurements) do
      case measurements[measurement_key] do
        value when is_number(value) -> value
        _ -> nil
      end
    else
      nil
    end
  end

  defp cooldown_allowed?(alert, current_time) do
    case :ets.lookup(@cooldown_table, alert.id) do
      [{_id, last_trigger}] ->
        current_time - last_trigger >= alert.cooldown_ms

      [] ->
        true
    end
  end

  defp record_cooldown(alert, current_time) do
    :ets.insert(@cooldown_table, {alert.id, current_time})
  end

  defp get_alert_state(alert_id) do
    case :ets.lookup(@state_table, alert_id) do
      [{^alert_id, state}] -> state
      [] -> nil
    end
  end

  defp update_alert_state(alert_id, state) do
    :ets.insert(@state_table, {alert_id, state})
  end

  defp send_notification(alert, value, metadata, type) do
    message_template = if type == :alert, do: alert.alert_message, else: alert.calm_message
    formatted_value = format_value(alert.event, value)
    message = String.replace(message_template, "%{value}", formatted_value)
    notifier_name = alert.notifier

    case alert.notifier do
      ^notifier_name
      when is_atom(notifier_name) and notifier_name in [:slack, :teams, :webhook, :console] ->
        case :ets.lookup(:nature_whistle_notifiers, notifier_name) do
          [{^notifier_name, config}] ->
            dispatch_to_notifier(alert.notifier, message, metadata, config)

          [] ->
            dispatch_to_notifier(alert.notifier, message, metadata, nil)
        end

      ^notifier_name when is_atom(notifier_name) ->
        if Code.ensure_loaded?(notifier_name) and function_exported?(notifier_name, :deliver, 3) do
          config = Map.get(alert, :notifier_config, [])
          notifier_name.deliver(message, metadata, config)
        else
          Logger.warning(
            "Custom notifier module #{inspect(notifier_name)} is not loaded or does not implement deliver/3"
          )
        end

      other ->
        Logger.warning("Unsupported notifier: #{inspect(other)}")
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

  defp dispatch_to_notifier(:console, message, metadata, _config) do
    NatureWhistle.Notifier.Console.deliver(message, metadata, %{})
  end

  defp dispatch_to_notifier(other, _message, _metadata, _config) do
    Logger.warning("Unsupported notifier: #{inspect(other)}")
  end

  defp format_value([:vm, :memory, :total], value) do
    mb = div(value, 1_048_576)
    "#{mb} MB"
  end

  defp format_value(_event, value) do
    to_string(value)
  end
end
