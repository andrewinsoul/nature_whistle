defmodule NatureWhistle.NotificationTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notification
  import ExUnit.CaptureLog

  setup do
    original_notifiers_config = Application.get_env(:nature_whistle, :notifiers_config)
    original_retry = Application.get_env(:nature_whistle, :retry)

    on_exit(fn ->
      if original_notifiers_config do
        Application.put_env(:nature_whistle, :notifiers_config, original_notifiers_config)
      else
        Application.delete_env(:nature_whistle, :notifiers_config)
      end

      if original_retry do
        Application.put_env(:nature_whistle, :retry, original_retry)
      else
        Application.delete_env(:nature_whistle, :retry)
      end
    end)

    base_alert = %{
      alert_message: "Alert template: %{value}",
      calm_message: "Calm template: %{value}",
      event: [:test, :metric],
      formatter: nil,
      notifiers: [:console]
    }

    {:ok, base_alert: base_alert}
  end

  test "format_value uses custom formatter function when provided", %{base_alert: base_alert} do
    alert = %{base_alert | formatter: fn val -> "CUSTOM-#{val}" end}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, 100, %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "Alert template: CUSTOM-100"
  end

  test "format_value falls back to string cast if custom formatter crashes", %{
    base_alert: base_alert
  } do
    alert = %{base_alert | formatter: fn _val -> raise "Crash!" end}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, 500, %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "NatureWhistle custom formatter failed"
    assert log =~ "Alert template: 500"
  end

  test "format_value formats specific VM total memory into MB strings", %{base_alert: base_alert} do
    alert = %{base_alert | event: [:vm, :memory, :total]}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, 10_485_760, %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "Alert template: 10 MB"
  end

  test "send_notification filters global notifiers against alert allowed target services", %{
    base_alert: base_alert
  } do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :console, service: :console, config: %{}},
      %{name: :slack_channel, service: :slack, config: %{webhook_url: "https://slack.com"}}
    ])

    alert = %{base_alert | notifiers: [:console]}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, "active", %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "[NatureWhistle] Alert template: active"
    refute log =~ "Unsupported notifier"
  end

  test "logs warning for unsupported notifier services", %{base_alert: base_alert} do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :invalid_target, service: :invalid_target, config: %{}}
    ])

    alert = %{base_alert | notifiers: [:invalid_target]}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, "data", %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "Unsupported notifier: :invalid_target"
  end

  test "logs warning when alert references a notifier that is missing from global config", %{
    base_alert: base_alert
  } do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :console, service: :console, config: %{}}
    ])

    alert = %{base_alert | notifiers: [:missing_channel]}

    log =
      capture_log(fn ->
        Notification.send_notification(alert, "data", %{}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "Notifier config not found for :missing_channel"
    refute log =~ "[NatureWhistle] Alert template: data"
  end

  test "dispatches a single alert to slack, teams and webhook targets", %{base_alert: base_alert} do
    test_pid = self()
    slack_bypass = Bypass.open()
    teams_bypass = Bypass.open()
    webhook_bypass = Bypass.open()

    Application.put_env(:nature_whistle, :notifiers_config, [
      %{
        name: :slack_channel,
        service: :slack,
        config: %{webhook_url: "http://localhost:#{slack_bypass.port}"}
      },
      %{
        name: :teams_channel,
        service: :teams,
        config: %{webhook_url: "http://localhost:#{teams_bypass.port}"}
      },
      %{
        name: :webhook_channel,
        service: :webhook,
        config: [
          webhook_url: "http://localhost:#{webhook_bypass.port}",
          method: :put,
          headers: [{"x-api-key", "abc123"}],
          payload: %{severity: "high"}
        ]
      }
    ])

    Bypass.expect_once(slack_bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {:slack_called, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    Bypass.expect_once(teams_bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(test_pid, {:teams_called, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    Bypass.expect_once(webhook_bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:webhook_called, conn.method, Plug.Conn.get_req_header(conn, "x-api-key"),
         Jason.decode!(body)}
      )

      Plug.Conn.resp(conn, 200, "ok")
    end)

    alert = %{base_alert | notifiers: [:slack_channel, :teams_channel, :webhook_channel]}

    Notification.send_notification(alert, "multi", %{source: :test}, :alert)

    assert_receive {:slack_called, %{"text" => "Alert template: multi"}}, 500
    assert_receive {:teams_called, %{"text" => "Alert template: multi"}}, 500

    assert_receive {:webhook_called, "PUT", ["abc123"],
                    %{"severity" => "high", "text" => "Alert template: multi"}},
                   500
  end
end
