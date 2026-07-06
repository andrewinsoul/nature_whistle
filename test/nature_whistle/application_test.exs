# File: test/nature_whistle/application_test.exs
defmodule NatureWhistle.ApplicationTest do
  use ExUnit.Case, async: false

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)
    original_retry = Application.get_env(:nature_whistle, :retry)

    on_exit(fn ->
      if original_alerts,
        do: Application.put_env(:nature_whistle, :alerts, original_alerts),
        else: Application.delete_env(:nature_whistle, :alerts)

      if original_retry,
        do: Application.put_env(:nature_whistle, :retry, original_retry),
        else: Application.delete_env(:nature_whistle, :retry)
    end)

    :ok
  end

  test "creates core ETS tables upon start" do
    assert :ets.info(@alerts_table) != :undefined
    assert :ets.info(@state_table) != :undefined
    assert :ets.info(@rate_limit_table) != :undefined
  end

  test "load_config_into_ets/1 correctly converts and loads configurations" do
    custom_alerts = [
      [
        id: :high_cpu,
        event: [:test, :cpu],
        threshold: 80,
        measurement_key: :value,
        notifier: :console
      ]
    ]

    Application.put_env(:nature_whistle, :alerts, custom_alerts)
    NatureWhistle.Application.load_config_into_ets(4)

    assert [{[:test, :cpu], [alert_map]}] = :ets.lookup(@alerts_table, [:test, :cpu])
    assert alert_map.id == :high_cpu
    assert alert_map.threshold == 80
  end

  test "load_config_into_ets/1 scales threshold for total run queue lengths by cpu cores" do
    queue_event = [:vm, :total_run_queue_lengths, :total]

    custom_alerts = [
      [
        id: :run_queue,
        event: queue_event,
        threshold: 2,
        notifier: :console
      ]
    ]

    Application.put_env(:nature_whistle, :alerts, custom_alerts)
    NatureWhistle.Application.load_config_into_ets(8)

    assert [{^queue_event, [alert_map]}] = :ets.lookup(@alerts_table, queue_event)
    assert alert_map.threshold == 16
  end

  test "load_config_into_ets/1 promotes legacy notifier keys into notifiers lists" do
    custom_alerts = [
      [
        id: :legacy_console,
        event: [:test, :legacy],
        threshold: 1,
        notifier: :console
      ]
    ]

    Application.put_env(:nature_whistle, :alerts, custom_alerts)
    NatureWhistle.Application.load_config_into_ets(4)

    assert [{[:test, :legacy], [alert_map]}] = :ets.lookup(@alerts_table, [:test, :legacy])
    assert alert_map.notifiers == [:console]
  end

  test "start/2 raises configuration error if base_delay_ms exceeds max_delay_ms" do
    Application.put_env(:nature_whistle, :retry, base_delay_ms: 5000, max_delay_ms: 1000)

    assert_raise RuntimeError, ~r/NatureWhistle Configuration Error/, fn ->
      NatureWhistle.Application.start(:normal, [])
    end
  end
end
