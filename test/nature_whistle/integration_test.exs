defmodule NatureWhistle.IntegrationTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.EventHandler
  alias NatureWhistle.BackgroundCleaner

  import NatureWhistle.TestHelpers
  import ExUnit.CaptureLog

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit

  setup do
    :ets.delete_all_objects(@alerts_table)
    :ets.delete_all_objects(@state_table)
    :ets.delete_all_objects(@rate_limit_table)

    :sys.replace_state(BackgroundCleaner, fn state ->
      %{state | timers: %{}}
    end)

    on_exit(fn ->
      :ets.delete_all_objects(@alerts_table)
      :ets.delete_all_objects(@state_table)
      :ets.delete_all_objects(@rate_limit_table)
    end)

    :ok
  end

  describe "NatureWhistle Integration Pipeline" do
    test "full lifecycle: breach triggers alert, resolution window handles recovery cleanly" do
      alert = %{
        id: :integration_latency_alert,
        event: [:test, :pipeline],
        measurement_key: :latency,
        threshold: 100,
        resolution_ms: 40,
        alert_message: "🚨 LATENCY BREACH: %{value}ms",
        calm_message: "✅ LATENCY NORMAL: %{value}ms",
        notifier: :console
      }

      :ets.insert(@alerts_table, {[:test, :pipeline], [alert]})

      log =
        capture_log(fn ->
          EventHandler.handle_event([:test, :pipeline], %{latency: 145}, %{}, %{})
          Process.sleep(10)
        end)

      assert [{_id, :breached, expiry}] = :ets.lookup(@state_table, alert.id)
      assert expiry > System.monotonic_time(:millisecond)

      assert log =~ "LATENCY BREACH: 145ms"

      assert_eventually(fn ->
        :ets.lookup(@state_table, alert.id) == []
      end)

      cleaner_state = :sys.get_state(BackgroundCleaner)
      refute Map.has_key?(cleaner_state.timers, alert.id)
    end

    test "debounce extension: repeated breaches push back the quiet window expiration" do
      alert = %{
        id: :integration_debounce_alert,
        event: [:test, :debounce],
        measurement_key: :value,
        threshold: 50,
        resolution_ms: 100,
        alert_message: "🚨 DEBOUNCE BREACH",
        calm_message: "✅ DEBOUNCE CALM",
        notifier: :console
      }

      :ets.insert(@alerts_table, {[:test, :debounce], [alert]})

      EventHandler.handle_event([:test, :debounce], %{value: 60}, %{}, %{})
      Process.sleep(5)
      assert [{_id, :breached, first_expiry}] = :ets.lookup(@state_table, alert.id)

      Process.sleep(20)

      EventHandler.handle_event([:test, :debounce], %{value: 75}, %{}, %{})
      Process.sleep(5)
      assert [{_id, :breached, second_expiry}] = :ets.lookup(@state_table, alert.id)

      assert second_expiry > first_expiry
    end

    test "rate limiting blocks alert cascade loops when rule constraints are breached" do
      alert = %{
        id: :integration_rate_limit_alert,
        event: [:test, :rate_limit],
        measurement_key: :value,
        threshold: 10,
        resolution_ms: 500,
        # Only 1 event allowed per window
        rate_limit: [window_ms: 10_000, max_events: 1],
        alert_message: "🚨 RATE ALERT",
        calm_message: "✅ RATE CALM",
        notifier: :console
      }

      :ets.insert(@alerts_table, {[:test, :rate_limit], [alert]})

      log_one =
        capture_log(fn ->
          EventHandler.handle_event([:test, :rate_limit], %{value: 15}, %{}, %{})
          Process.sleep(5)
        end)

      assert log_one =~ "RATE ALERT"

      log_two =
        capture_log(fn ->
          EventHandler.handle_event([:test, :rate_limit], %{value: 20}, %{}, %{})
          Process.sleep(5)
        end)

      refute log_two =~ "RATE ALERT"
    end

    test "sliding window blocks execution once frequency density bounds are exceeded" do
      alert = %{
        id: :integration_sliding_window_alert,
        event: [:test, :sliding],
        measurement_key: :value,
        threshold: 10,
        resolution_ms: 500,
        sliding_window: [window_ms: 30_000, max_events: 2],
        alert_message: "🚨 SLIDING BREACH",
        calm_message: "✅ SLIDING CALM",
        notifier: :console
      }

      :ets.insert(@alerts_table, {[:test, :sliding], [alert]})

      log_one =
        capture_log(fn ->
          EventHandler.handle_event([:test, :sliding], %{value: 12}, %{}, %{})
          Process.sleep(5)
        end)

      assert log_one =~ "SLIDING BREACH"

      EventHandler.handle_event([:test, :sliding], %{value: 15}, %{}, %{})
      Process.sleep(5)

      log_three =
        capture_log(fn ->
          EventHandler.handle_event([:test, :sliding], %{value: 18}, %{}, %{})
          Process.sleep(5)
        end)

      refute log_three =~ "SLIDING BREACH"
    end
  end
end
