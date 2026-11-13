defmodule NatureWhistle.SetupTest do
  use ExUnit.Case, async: false

  @event [:setup, :telemetry, :event]

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)
    original_mailbox_monitor = Application.get_env(:nature_whistle, :mailbox_monitor)
    original_sensitive_metrics = Application.get_env(:nature_whistle, :sensitive_metrics)

    on_exit(fn ->
      restore_env(:alerts, original_alerts)
      restore_env(:mailbox_monitor, original_mailbox_monitor)
      restore_env(:sensitive_metrics, original_sensitive_metrics)
      NatureWhistle.Setup.init()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:nature_whistle, key)
  defp restore_env(key, value), do: Application.put_env(:nature_whistle, key, value)

  test "init/0 accepts valid sensitive metric event names" do
    Application.put_env(:nature_whistle, :sensitive_metrics, [
      [:billing, :customer, :balance],
      [:auth, :user, :identity]
    ])

    assert is_list(NatureWhistle.Setup.init())
  end

  test "init/0 rejects sensitive metrics that are not a list of event names" do
    Application.put_env(:nature_whistle, :sensitive_metrics, [:billing, :balance])

    assert_raise ArgumentError, ~r/:sensitive_metrics/, fn ->
      NatureWhistle.Setup.init()
    end
  end

  test "init/0 rejects empty or malformed sensitive metric event names" do
    for invalid_metrics <- [
          [[]],
          [[:billing, "balance"]],
          [[:billing, 123]],
          ["billing.balance"]
        ] do
      Application.put_env(:nature_whistle, :sensitive_metrics, invalid_metrics)

      assert_raise ArgumentError, ~r/:sensitive_metrics/, fn ->
        NatureWhistle.Setup.init()
      end
    end
  end

  test "mailbox monitoring is disabled by default" do
    Application.delete_env(:nature_whistle, :mailbox_monitor)

    assert [] = NatureWhistle.Setup.mailbox_monitor_children()
  end

  test "mailbox monitoring returns a child when explicitly enabled" do
    Application.put_env(:nature_whistle, :mailbox_monitor,
      enabled: true,
      mode: :own,
      threshold: 10,
      disable_threshold: 5,
      duration_ms: 100
    )

    assert [{NatureWhistle.MailboxMonitor, options}] =
             NatureWhistle.Setup.mailbox_monitor_children()

    assert Keyword.get(options, :enabled) == true
    assert Keyword.get(options, :threshold) == 10
  end

  test "disabled mailbox mode does not add a child" do
    Application.put_env(:nature_whistle, :mailbox_monitor, enabled: true, mode: :disabled)

    assert [] = NatureWhistle.Setup.mailbox_monitor_children()
  end

  test "init/0 loads alerts into ETS and attaches their telemetry handlers" do
    Application.put_env(:nature_whistle, :alerts, [
      %{
        id: :setup_event_alert,
        event: @event,
        condition: :event,
        alert_message: "Setup event",
        notifiers: [:console]
      }
    ])

    assert [] = NatureWhistle.Setup.init()
    assert [{@event, [alert]}] = :ets.lookup(:nature_whistle_alerts, @event)
    assert alert.id == :setup_event_alert

    assert [{@event, handler_id}] =
             :ets.lookup(:nature_whistle_telemetry_handlers, @event)

    assert is_binary(handler_id)

    :telemetry.execute(@event, %{}, %{})
  end
end
