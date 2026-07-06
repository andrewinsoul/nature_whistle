defmodule NatureWhistle.BackgroundCleanerTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.BackgroundCleaner
  import ExUnit.CaptureLog

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)
    original_history = Application.get_env(:nature_whistle, :max_window_history_ms)

    alert = %{
      id: :latency_alert,
      event: [:test, :latency],
      measurement_key: :latency,
      threshold: 10,
      alert_message: "Alert!",
      calm_message: "Calm!",
      resolution_ms: 1_000,
      debounce_ms: 1_000,
      notifiers: [:console]
    }

    Application.put_env(:nature_whistle, :alerts, [alert])
    Application.put_env(:nature_whistle, :max_window_history_ms, 1_000)

    if :ets.info(@alerts_table) == :undefined do
      :ets.new(@alerts_table, [:set, :public, :named_table])
    end

    if :ets.info(@state_table) == :undefined do
      :ets.new(@state_table, [:set, :public, :named_table])
    end

    if :ets.info(@rate_limit_table) == :undefined do
      :ets.new(@rate_limit_table, [:ordered_set, :public, :named_table])
    end

    :ets.delete_all_objects(@alerts_table)
    :ets.delete_all_objects(@state_table)
    :ets.delete_all_objects(@rate_limit_table)

    pid = Process.whereis(BackgroundCleaner)

    :sys.replace_state(pid, fn state ->
      %{state | sweep_interval_ms: 1_000, max_window_history_ms: 1_000, timers: %{}}
    end)

    on_exit(fn ->
      if original_alerts do
        Application.put_env(:nature_whistle, :alerts, original_alerts)
      else
        Application.delete_env(:nature_whistle, :alerts)
      end

      if original_history do
        Application.put_env(:nature_whistle, :max_window_history_ms, original_history)
      else
        Application.delete_env(:nature_whistle, :max_window_history_ms)
      end
    end)

    {:ok, alert: alert}
  end

  test "start_link initializes the internal state and sweep interval", %{alert: _alert} do
    state = :sys.get_state(BackgroundCleaner)

    assert state.sweep_interval_ms == 1_000
    assert state.max_window_history_ms == 1_000
    assert state.timers == %{}
  end

  test "start_debounce/4 and extend_debounce/4 update the in-memory timer registry", %{
    alert: alert
  } do
    alert_id = alert.id

    BackgroundCleaner.start_debounce(alert.id, alert.resolution_ms, 11, %{kind: :initial})
    Process.sleep(50)

    state = :sys.get_state(BackgroundCleaner)
    assert %{^alert_id => %{value: 11, metadata: %{kind: :initial}}} = state.timers

    BackgroundCleaner.extend_debounce(alert.id, alert.resolution_ms, 12, %{kind: :extended})
    Process.sleep(50)

    state = :sys.get_state(BackgroundCleaner)
    assert %{^alert_id => %{value: 12, metadata: %{kind: :extended}}} = state.timers
  end

  test "handle_info(:sweep) prunes expired buckets and keeps recent rate limit entries", %{
    alert: alert
  } do
    now = System.monotonic_time(:millisecond)
    expired_bucket = div(now - 20_000, 10_000) * 10_000
    fresh_bucket = div(now, 10_000) * 10_000

    :ets.insert(@rate_limit_table, {{:rate_limit, alert.id}, [now - 2_000, now]})
    :ets.insert(@rate_limit_table, {{{:sliding_window, alert.id}, expired_bucket}, 1})
    :ets.insert(@rate_limit_table, {{{:sliding_window, alert.id}, fresh_bucket}, 1})

    send(BackgroundCleaner, :sweep)
    Process.sleep(50)

    assert :ets.lookup(@rate_limit_table, {:rate_limit, alert.id}) == [
             {{:rate_limit, alert.id}, [now]}
           ]

    assert :ets.lookup(@rate_limit_table, {{:sliding_window, alert.id}, expired_bucket}) == []

    assert :ets.lookup(@rate_limit_table, {{:sliding_window, alert.id}, fresh_bucket}) == [
             {{{:sliding_window, alert.id}, fresh_bucket}, 1}
           ]
  end

  test "resolve_alert message clears alert state and emits calm notification", %{alert: alert} do
    BackgroundCleaner.start_debounce(alert.id, alert.resolution_ms, 11, %{request_id: 123})
    Process.sleep(50)

    log =
      capture_log(fn ->
        send(BackgroundCleaner, {:resolve_alert, alert.id})
        Process.sleep(50)
      end)

    assert :ets.lookup(@state_table, alert.id) == []
    assert log =~ "Calm!"
  end
end
