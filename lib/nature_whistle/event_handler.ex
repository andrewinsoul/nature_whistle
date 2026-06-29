defmodule NatureWhistle.EventHandler do
  @moduledoc """
  Telemetry event handler for NatureWhistle.
  """
  alias NatureWhistle.BackgroundCleaner

  require Logger
  import NatureWhistle.{EventGuard, Notification}

  @alerts_table :nature_whistle_alerts

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

  defp manage_debounce_and_alert(alert, value, metadata) do
    current_time = System.monotonic_time(:millisecond)

    case :ets.lookup(:nature_whistle_alert_state, alert.id) do
      [] ->
        BackgroundCleaner.start_debounce(alert.id, alert.resolution_ms, value, metadata)

        :ets.insert(
          :nature_whistle_alert_state,
          {alert.id, :breached, current_time + alert.resolution_ms}
        )

        send_notification(alert, value, metadata, :alert)

      [{_id, :breached, _expiry}] ->
        if value >= alert.threshold do
          new_expiry = current_time + alert.resolution_ms
          :ets.insert(:nature_whistle_alert_state, {alert.id, :breached, new_expiry})

          BackgroundCleaner.extend_debounce(alert.id, alert.resolution_ms, value, metadata)
        else
          :ok
        end
    end
  end

  defp check_alert(alert, measurements, metadata) do
    value = extract_value(measurements, alert.measurement_key)

    if is_number(value) and value >= alert.threshold do
      current_time = System.monotonic_time(:millisecond)
      record_sliding_window_event(alert, current_time)

      with true <- allow_rate_limit?(alert, current_time),
           false <- allow_sliding_window?(alert, current_time) do
        manage_debounce_and_alert(alert, value, metadata)
        record_rate_limit(alert, current_time)
      else
        _ -> :ok
      end
    else
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
end
