defmodule NatureWhistle.EventHandler do
  @moduledoc """
  Telemetry event handler for NatureWhistle.

  This module is the hot path of the library. It is called directly by
  `:telemetry` whenever a configured event is emitted, so the code here is kept
  intentionally small and defensive:

  - locate the alerts configured for the event
  - evaluate the alert condition
  - apply rate-limit and sliding-window suppression
  - transition the alert into a breached state if delivery is allowed

  Any exception is rescued and logged so alert processing never crashes the
  host application.
  """

  alias NatureWhistle.BackgroundCleaner

  require Logger

  import NatureWhistle.{EventGuard, Notification}

  @alerts_table :nature_whistle_alerts
  @alert_state_table :nature_whistle_alert_state
  @correlation_state_table :nature_whistle_correlation_state

  @doc """
  Handles a single telemetry event.

  Parameters:

  - `event` - the telemetry event name, for example `[:vm, :memory, :total]`
  - `measurements` - the telemetry measurement map
  - `metadata` - arbitrary metadata emitted with the event
  - `_config` - telemetry callback config, currently unused

  The function is designed to be called by `:telemetry.attach/4`. It performs
  all alert evaluation for that event and quietly returns `:ok` when no alert
  is configured or no actionable condition is detected.
  """
  def handle_event(event, measurements, metadata, _config) do
    handle_correlations(event, metadata)

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

  @doc """
  Resolves an aggregate alert after its failure window expires.

  The `FailureTracker` calls this function after a sweep. An alert is only
  resolved when no other failure key for the same alert remains active. This
  prevents one recovered key from clearing an alert that is still active for a
  different key.
  """
  def handle_aggregate_recovery({_alert_id, _failure_key, true}), do: :ok

  def handle_aggregate_recovery({alert_id, failure_key, false}) do
    case :ets.lookup(@alert_state_table, alert_id) do
      [{^alert_id, :breached, _expiry}] ->
        :ets.delete(@alert_state_table, alert_id)

        if alert = NatureWhistle.get_alert_config(alert_id) do
          send_notification(
            alert,
            0,
            %{aggregate_key: failure_key, recovery_reason: :window_expired},
            :calm
          )
        end

      [] ->
        :ok
    end
  end

  def handle_aggregate_recovery(_recovery), do: :ok

  defp handle_correlations(event, metadata) do
    correlations =
      :ets.foldl(
        fn {_event, alerts}, acc ->
          Enum.reduce(alerts, acc, fn alert, correlations ->
            case Map.get(alert, :correlation) do
              %{recovery_event: ^event} ->
                [alert | correlations]

              _ ->
                correlations
            end
          end)
        end,
        [],
        @alerts_table
      )

    Enum.each(correlations, &handle_correlation(&1, metadata))
  end

  defp handle_correlation(
         %{correlation: correlation} = alert,
         metadata
       ) do
    key = correlation.key.(metadata)
    correlation_id = {alert.id, key}

    case :ets.lookup(@correlation_state_table, correlation_id) do
      [{^correlation_id, :failed}] ->
        if correlation.recovery?.(metadata) do
          send_notification(alert, 1, metadata, :calm)

          :ets.delete(
            @correlation_state_table,
            correlation_id
          )
        end

      [] ->
        :ok
    end
  end

  defp handle_correlation(_alert, _metadata), do: :ok

  defp check_alert(%{condition: :event} = alert, _measurements, metadata) do
    handle_breach(alert, Map.get(alert, :event_value, 1), metadata)
    record_correlation(alert, metadata)
  end

  defp check_alert(
         %{condition: {:aggregate, aggregate}} = alert,
         _measurements,
         metadata
       ) do
    key = Keyword.fetch!(aggregate, :key).(metadata)
    failures = Keyword.fetch!(aggregate, :failures)
    within_ms = Keyword.fetch!(aggregate, :within_ms)

    case NatureWhistle.FailureTracker.record_failure(
           alert.id,
           key,
           failures,
           within_ms
         ) do
      {:triggered, count} ->
        handle_breach(alert, count, metadata)

      {:below_threshold, _count} ->
        :ok

      {:active, _count} ->
        :ok
    end
  end

  defp check_alert(alert, measurements, metadata) do
    value = extract_value(measurements, alert.measurement_key)

    cond do
      not is_number(value) ->
        :ok

      value >= alert.threshold ->
        handle_breach(alert, value, metadata)

      true ->
        handle_recovery(alert, value, metadata)
    end
  end

  defp record_correlation(
         %{correlation: %{key: key}} = alert,
         metadata
       ) do
    correlation_key = key.(metadata)

    :ets.insert(
      :nature_whistle_correlation_state,
      {{alert.id, correlation_key}, :failed}
    )
  end

  defp record_correlation(_alert, _metadata), do: :ok

  defp handle_breach(alert, value, metadata) do
    current_time = System.monotonic_time(:millisecond)

    record_sliding_window_event_if_configured(alert, current_time)

    with true <- allow_rate_limit?(alert, current_time),
         false <- allow_sliding_window?(alert, current_time) do
      BackgroundCleaner.cancel_recovery(alert.id)

      manage_debounce_and_alert(alert, value, metadata)

      record_rate_limit_if_configured(alert, current_time)
    else
      _ ->
        :ok
    end
  end

  defp record_sliding_window_event_if_configured(alert, now) do
    if is_list(Map.get(alert, :sliding_window)) do
      record_sliding_window_event(alert, now)
    else
      :ok
    end
  end

  defp record_rate_limit_if_configured(alert, now) do
    if is_list(Map.get(alert, :rate_limit)) do
      record_rate_limit(alert, now)
    else
      :ok
    end
  end

  defp manage_debounce_and_alert(alert, value, metadata) do
    current_time = System.monotonic_time(:millisecond)

    case :ets.lookup(@alert_state_table, alert.id) do
      [] ->
        :ets.insert(
          @alert_state_table,
          {alert.id, :breached, current_time}
        )

        send_notification(alert, value, metadata, :alert)

      [{_id, :breached, _expiry}] ->
        :ets.insert(
          @alert_state_table,
          {alert.id, :breached, current_time}
        )
    end
  end

  defp handle_recovery(alert, value, metadata) do
    case :ets.lookup(@alert_state_table, alert.id) do
      [{_id, :breached, _expiry}] ->
        BackgroundCleaner.start_recovery(
          alert.id,
          alert.resolution_ms,
          value,
          metadata
        )

      [] ->
        :ok
    end
  end

  defp extract_value(measurements, measurement_key) do
    if is_map(measurements) do
      case measurements[measurement_key] do
        value when is_number(value) ->
          value

        _ ->
          nil
      end
    else
      nil
    end
  end
end
