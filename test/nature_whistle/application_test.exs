# File: test/nature_whistle/application_test.exs
defmodule NatureWhistle.ApplicationTest do
  use ExUnit.Case, async: false

  @alerts_table :nature_whistle_alerts
  @state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)
    original_retry = Application.get_env(:nature_whistle, :retry)
    original_notifiers_config = Application.get_env(:nature_whistle, :notifiers_config)

    on_exit(fn ->
      restore_env(:alerts, original_alerts)
      restore_env(:retry, original_retry)
      restore_env(:notifiers_config, original_notifiers_config)
      restore_alert_runtime(original_alerts)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:nature_whistle, key)
  defp restore_env(key, value), do: Application.put_env(:nature_whistle, key, value)

  defp restore_alert_runtime(original_alerts) do
    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

    metrics =
      :ets.tab2list(@alerts_table)
      |> Enum.flat_map(fn {_event, alerts} -> alerts end)
      |> Enum.filter(&match?([:vm | _], &1.event))
      |> NatureWhistle.Packs.Beam.metrics()

    if Process.whereis(NatureWhistle.Packs.Beam.Collector) do
      :ok = NatureWhistle.Packs.Beam.Collector.configure(metrics)
    end

    if original_alerts == nil do
      Application.delete_env(:nature_whistle, :alerts)
    end
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

  test "register_alert/1 adds a runtime alert and makes it available by id" do
    alert = %{
      id: :runtime_alert,
      event: [:runtime, :alert, :stop],
      measurement_key: :duration,
      threshold: 500,
      notifiers: [:console]
    }

    assert {:ok, registered} = NatureWhistle.register_alert(alert)
    assert registered.id == :runtime_alert
    assert NatureWhistle.get_alert_config(:runtime_alert).id == :runtime_alert

    assert [{_, [runtime_alert]}] =
             :ets.lookup(:nature_whistle_alerts, [:runtime, :alert, :stop])

    assert runtime_alert.id == :runtime_alert

    assert :ok = NatureWhistle.unregister_alert(:runtime_alert)
    assert NatureWhistle.get_alert_config(:runtime_alert) == nil
    assert :ets.lookup(:nature_whistle_alerts, [:runtime, :alert, :stop]) == []
  end

  test "register_alert/1 rejects duplicate alert ids" do
    alert = %{
      id: :runtime_duplicate,
      event: [:runtime, :duplicate],
      threshold: 1,
      notifiers: [:console]
    }

    assert {:ok, _} = NatureWhistle.register_alert(alert)
    assert {:error, :already_registered} = NatureWhistle.register_alert(alert)

    assert :ok = NatureWhistle.unregister_alert(:runtime_duplicate)
  end

  test "runtime alerts use configured notifier profiles" do
    test_pid = self()
    bypass = Bypass.open()

    Application.put_env(:nature_whistle, :notifiers_config, [
      %{
        name: :runtime_slack,
        service: :slack,
        config: %{webhook_url: "http://localhost:#{bypass.port}"}
      }
    ])

    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:slack_called, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    alert = %{
      id: :runtime_slack_alert,
      event: [:runtime, :slack, :stop],
      measurement_key: :duration,
      threshold: 500,
      alert_message: "Runtime slow: %{value}",
      notifiers: [:runtime_slack]
    }

    assert {:ok, _} = NatureWhistle.register_alert(alert)

    :telemetry.execute([:runtime, :slack, :stop], %{duration: 501}, %{})

    assert_receive {:slack_called, %{"text" => "Runtime slow: 501"}}, 500
    assert :ok = NatureWhistle.unregister_alert(:runtime_slack_alert)
  end
end
