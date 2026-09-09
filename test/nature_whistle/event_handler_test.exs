defmodule NatureWhistle.EventHandlerTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.EventHandler
  alias NatureWhistle.Packs.Oban
  import ExUnit.CaptureLog

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit
  @correlation_state_table :nature_whistle_correlation_state

  setup do
    if :ets.info(@alerts_table) == :undefined,
      do: :ets.new(@alerts_table, [:set, :public, :named_table])

    if :ets.info(@state_table) == :undefined,
      do: :ets.new(@state_table, [:set, :public, :named_table])

    if :ets.info(@rate_limit_table) == :undefined,
      do: :ets.new(@rate_limit_table, [:ordered_set, :public, :named_table])

    if :ets.info(@correlation_state_table) == :undefined,
      do: :ets.new(@correlation_state_table, [:set, :public, :named_table])

    :ets.delete_all_objects(@alerts_table)
    :ets.delete_all_objects(@state_table)
    :ets.delete_all_objects(@rate_limit_table)
    :ets.delete_all_objects(@correlation_state_table)

    test_alert = %{
      id: :test_latency_alert,
      event: [:iex, :test],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 10_000,
      debounce_ms: 0,
      alert_message: "🚨 ALERT!",
      calm_message: "✨ CALM!"
    }

    :ets.insert(@alerts_table, {[:iex, :test], [test_alert]})

    [oban_alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_job_exception))

    :ets.insert(
      @alerts_table,
      {oban_alert.event, [oban_alert]}
    )

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

  test "handle_event/4 starts recovery when a breached metric becomes healthy" do
    alert = %{
      id: :recovery_alert,
      event: [:iex, :recovery],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 1_000,
      debounce_ms: 0,
      alert_message: "🚨 RECOVERY ALERT!",
      calm_message: "✨ RECOVERED!",
      notifiers: [:console]
    }

    :ets.insert(@alerts_table, {alert.event, [alert]})

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      Process.sleep(50)
    end)

    alert_id = alert.id

    assert [{^alert_id, :breached, _expiry}] =
             :ets.lookup(@state_table, alert.id)

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 50}, %{}, nil)
      Process.sleep(50)
    end)

    assert [{^alert_id, :breached, _expiry}] =
             :ets.lookup(@state_table, alert.id)
  end

  test "handle_event/4 resolves an alert after the metric stays healthy for resolution_ms" do
    alert = %{
      id: :successful_recovery,
      event: [:iex, :successful_recovery],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 100,
      debounce_ms: 0,
      alert_message: "🚨 ALERT!",
      calm_message: "✨ RECOVERED!",
      notifiers: [:console]
    }

    original_alerts = Application.get_env(:nature_whistle, :alerts)
    alert_id = alert.id

    Application.put_env(:nature_whistle, :alerts, [alert])
    :ets.insert(@alerts_table, {alert.event, [alert]})

    on_exit(fn ->
      if original_alerts do
        Application.put_env(:nature_whistle, :alerts, original_alerts)
      else
        Application.delete_env(:nature_whistle, :alerts)
      end
    end)

    capture_log(fn ->
      :ok =
        EventHandler.handle_event(
          alert.event,
          %{latency: 150},
          %{},
          nil
        )

      Process.sleep(20)
    end)

    assert [{^alert_id, :breached, _expiry}] =
             :ets.lookup(@state_table, alert.id)

    log =
      capture_log(fn ->
        :ok =
          EventHandler.handle_event(
            alert.event,
            %{latency: 50},
            %{},
            nil
          )

        Process.sleep(300)
      end)

    assert log =~ "✨ RECOVERED!"
    assert :ets.lookup(@state_table, alert.id) == []
  end

  test "handle_event/4 cancels recovery when the metric breaches again" do
    alert = %{
      id: :interrupted_recovery,
      event: [:iex, :interrupted_recovery],
      measurement_key: :latency,
      threshold: 100,
      resolution_ms: 200,
      debounce_ms: 0,
      alert_message: "🚨 ALERT!",
      calm_message: "✨ RECOVERED!",
      notifiers: [:console]
    }

    :ets.insert(@alerts_table, {alert.event, [alert]})

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      Process.sleep(20)
    end)

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 50}, %{}, nil)
      Process.sleep(50)
    end)

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 150}, %{}, nil)
      Process.sleep(50)
    end)

    alert_id = alert.id

    assert [{^alert_id, :breached, _expiry}] =
             :ets.lookup(@state_table, alert.id)

    Process.sleep(150)

    assert [{^alert_id, :breached, _expiry}] =
             :ets.lookup(@state_table, alert.id)
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

  @tag :skip
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

    IO.inspect(
      :sys.get_state(NatureWhistle.BackgroundCleaner),
      label: "AFTER FIRST BREACH"
    )

    :ets.insert(@state_table, {alert.id, :breached, System.monotonic_time(:millisecond)})

    capture_log(fn ->
      :ok = EventHandler.handle_event(alert.event, %{latency: 200}, %{}, nil)
      Process.sleep(50)
    end)

    state = :sys.get_state(NatureWhistle.BackgroundCleaner)
    alert_id = alert.id
    assert %{^alert_id => %{value: 200}} = state.timers
  end

  test "records a failed correlation for an event" do
    insert_oban_exception_alert()

    execute_oban_exception(456)

    assert [{{:nature_whistle_oban_job_exception, {456, _, _}}, :failed}] =
             :ets.match_object(
               :nature_whistle_correlation_state,
               {{:nature_whistle_oban_job_exception, {456, :_, :_}}, :failed}
             )
  end

  test "does not recover a different job" do
    insert_oban_exception_alert()

    execute_oban_exception(456)

    execute_oban_success(789)

    assert [{{:nature_whistle_oban_job_exception, {456, _, _}}, :failed}] =
             :ets.match_object(
               :nature_whistle_correlation_state,
               {{:nature_whistle_oban_job_exception, {456, :_, :_}}, :failed}
             )
  end

  test "recovers the matching job" do
    execute_oban_exception(456)

    execute_oban_success(456)

    assert [] =
             :ets.match_object(
               :nature_whistle_correlation_state,
               {{:nature_whistle_oban_job_exception, {456, :_, :_}}, :failed}
             )
  end

  test "tracks multiple failed jobs independently" do
    insert_oban_exception_alert()

    execute_oban_exception(456)
    execute_oban_exception(789)
    execute_oban_success(456)

    assert [
             {{:nature_whistle_oban_job_exception, {789, _, _}}, :failed}
           ] =
             :ets.match_object(
               @correlation_state_table,
               {{:nature_whistle_oban_job_exception, {789, :_, :_}}, :failed}
             )
  end

  defp execute_oban_exception(job_id) do
    EventHandler.handle_event(
      [:oban, :job, :exception],
      %{
        duration: 500_000_000,
        queue_time: 100_000_000,
        reductions: 1_000,
        memory: 10_000
      },
      %{
        state: :retryable,
        kind: :error,
        reason: %RuntimeError{message: "temporary failure"},
        job: %{
          id: job_id,
          worker: "MyApp.Workers.EmailWorker",
          queue: "default"
        }
      },
      nil
    )
  end

  defp execute_oban_success(job_id) do
    EventHandler.handle_event(
      [:oban, :job, :stop],
      %{
        duration: 500_000_000,
        queue_time: 100_000_000,
        reductions: 1_000,
        memory: 10_000
      },
      %{
        state: :success,
        job: %{
          id: job_id,
          worker: "MyApp.Workers.EmailWorker",
          queue: "default"
        }
      },
      nil
    )
  end

  defp insert_oban_exception_alert do
    [alert] =
      NatureWhistle.Packs.Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_job_exception))

    alert = Map.put(alert, :event_value, 1)

    :ets.insert(@alerts_table, {alert.event, [alert]})

    alert
  end
end
