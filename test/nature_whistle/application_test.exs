defmodule NatureWhistle.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    for table <- [:nature_whistle_alerts, :nature_whistle_notifiers, :nature_whistle_alert_state] do
      if :ets.whereis(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end

    :ok
  end

  test "creates ETS tables on start" do
    assert :ets.whereis(:nature_whistle_alerts) != :undefined
    assert :ets.whereis(:nature_whistle_notifiers) != :undefined
    assert :ets.whereis(:nature_whistle_alert_state) != :undefined
  end

  test "loads default alerts when none configured" do
    # Temporarily remove custom config
    Application.delete_env(:nature_whistle, :alerts)
    Application.delete_env(:nature_whistle, :notifiers)

    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

    alerts = :ets.lookup(:nature_whistle_alerts, [:vm, :memory, :total])

    assert length(alerts) == 1

    [{_, alert_list}] = alerts

    assert is_list(alert_list)
    alert = hd(alert_list)
    assert alert.id == :high_memory
    assert alert.threshold == 1_073_741_824
  end

  test "loads user provided alerts" do
    custom_alerts = [
      %{
        id: :test_alert,
        event: [:test, :event],
        measurement_key: :value,
        threshold: 100,
        alert_message: "Test alert",
        calm_message: "Test calm",
        notifier: :console
      }
    ]

    Application.put_env(:nature_whistle, :alerts, custom_alerts)
    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())
    alerts = :ets.lookup(:nature_whistle_alerts, [:test, :event])
    assert length(alerts) == 1
    [{_, [alert]}] = alerts
    assert alert.id == :test_alert
  end
end
