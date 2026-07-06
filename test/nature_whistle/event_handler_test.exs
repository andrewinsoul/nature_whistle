# File: test/nature_whistle/event_handler_test.exs
defmodule NatureWhistle.EventHandlerTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.EventHandler
  import ExUnit.CaptureLog

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit

  setup do
    if :ets.info(@alerts_table) == :undefined,
      do: :ets.new(@alerts_table, [:set, :public, :named_table])

    if :ets.info(@state_table) == :undefined,
      do: :ets.new(@state_table, [:set, :public, :named_table])

    if :ets.info(@rate_limit_table) == :undefined,
      do: :ets.new(@rate_limit_table, [:ordered_set, :public, :named_table])

    :ets.delete_all_objects(@alerts_table)
    :ets.delete_all_objects(@state_table)
    :ets.delete_all_objects(@rate_limit_table)

    test_alert = %{
      id: :test_latency_alert,
      event: [:iex, :test],
      measurement_key: :latency,
      threshold: 100,
      # Keep the alert active long enough for assertions.
      resolution_ms: 10_000,
      # Set to 0 for immediate alerting
      debounce_ms: 0,
      alert_message: "🚨 ALERT!",
      calm_message: "✨ CALM!"
    }

    :ets.insert(@alerts_table, {[:iex, :test], [test_alert]})
    {:ok, alert: test_alert}
  end

  test "handle_event/4 alerts immediately when threshold is breached without window or rate limit" do
    log =
      capture_log(fn ->
        :ok = EventHandler.handle_event([:iex, :test], %{latency: 150}, %{}, nil)
        Process.sleep(50)
      end)

    assert log =~ "🚨 ALERT!"

    assert match?(
             [{:test_latency_alert, :breached, _expiry}],
             :ets.lookup(@state_table, :test_latency_alert)
           )
  end

  test "handle_event/4 keeps breached state in place until resolution timer fires" do
    :ets.insert(
      @state_table,
      {:test_latency_alert, :breached, System.monotonic_time(:millisecond)}
    )

    log =
      capture_log(fn ->
        :ok = EventHandler.handle_event([:iex, :test], %{latency: 50}, %{}, nil)
        Process.sleep(50)
      end)

    assert log == ""

    assert match?(
             [{:test_latency_alert, :breached, _expiry}],
             :ets.lookup(@state_table, :test_latency_alert)
           )
  end

  test "handle_event/4 ignores completely untracked telemetry events" do
    log =
      capture_log(fn ->
        :ok = EventHandler.handle_event([:untracked, :event], %{value: 1000}, %{}, nil)
      end)

    assert log == ""
  end

  test "handle_event/4 ignores event when measurement key is missing from payload" do
    log =
      capture_log(fn ->
        :ok = EventHandler.handle_event([:iex, :test], %{wrong_key: 150}, %{}, nil)
      end)

    assert log == ""
  end

  test "handle_event/4 records rate limited breaches and stops alerting once the cap is reached" do
    alert = %{
      id: :rate_limited_alert,
      event: [:iex, :rate_limited],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 10_000,
      debounce_ms: 0,
      rate_limit: [window_ms: 60_000, max_events: 1],
      alert_message: "🚨 RATE-LIMITED ALERT!",
      calm_message: "✨ RATE-LIMITED CALM!",
      notifiers: [:console]
    }

    :ets.insert(@alerts_table, {alert.event, [alert]})

    first_log =
      capture_log(fn ->
        :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
        Process.sleep(50)
      end)

    assert first_log =~ "🚨 RATE-LIMITED ALERT!"
    assert :ets.lookup(@rate_limit_table, {:rate_limit, alert.id}) != []

    second_log =
      capture_log(fn ->
        :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      end)

    assert second_log == ""
  end

  test "handle_event/4 suppresses alerting once the sliding window threshold is reached" do
    alert = %{
      id: :sliding_window_alert,
      event: [:iex, :windowed],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 10_000,
      debounce_ms: 0,
      sliding_window: [window_ms: 60_000, max_events: 1],
      alert_message: "🚨 WINDOW ALERT!",
      calm_message: "✨ WINDOW CALM!",
      notifiers: [:console]
    }

    :ets.insert(@alerts_table, {alert.event, [alert]})

    log =
      capture_log(fn ->
        :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      end)

    assert log == ""
    assert :ets.lookup(@state_table, alert.id) == []
  end

  test "handle_event/4 extends the debounce timer when a breached metric stays high" do
    alert = %{
      id: :extended_alert,
      event: [:iex, :extended],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 1_000,
      debounce_ms: 0,
      alert_message: "🚨 EXTENDED ALERT!",
      calm_message: "✨ EXTENDED CALM!",
      notifiers: [:console]
    }

    :ets.insert(@alerts_table, {alert.event, [alert]})

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      Process.sleep(50)
    end)

    :ets.insert(@state_table, {alert.id, :breached, System.monotonic_time(:millisecond)})

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 200}, %{}, nil)
      Process.sleep(50)
    end)

    state = :sys.get_state(NatureWhistle.BackgroundCleaner)
    alert_id = alert.id
    assert %{^alert_id => %{value: 200}} = state.timers
  end
end
