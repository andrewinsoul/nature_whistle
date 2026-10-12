defmodule NatureWhistle.NotificationTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notification
  alias NatureWhistle.Util.CheckNotifierConfig
  import ExUnit.CaptureLog

  setup do
    original_notifiers_config = Application.get_env(:nature_whistle, :notifiers_config)
    original_retry = Application.get_env(:nature_whistle, :retry)

    original_sensitive_metadata_keys =
      Application.get_env(:nature_whistle, :sensitive_metadata_keys)

    original_sensitive_metrics = Application.get_env(:nature_whistle, :sensitive_metrics)

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

      if original_sensitive_metadata_keys do
        Application.put_env(
          :nature_whistle,
          :sensitive_metadata_keys,
          original_sensitive_metadata_keys
        )
      else
        Application.delete_env(:nature_whistle, :sensitive_metadata_keys)
      end

      if original_sensitive_metrics do
        Application.put_env(:nature_whistle, :sensitive_metrics, original_sensitive_metrics)
      else
        Application.delete_env(:nature_whistle, :sensitive_metrics)
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

  test "redacts built-in and developer-configured metadata keys recursively" do
    Application.put_env(:nature_whistle, :sensitive_metadata_keys, [
      :customer_email,
      :account_id
    ])

    metadata = %{
      "apiKey" => "api-secret",
      request: %{
        "account-id" => "acct-123",
        customer_email: "person@example.com",
        harmless: "visible"
      },
      nested: [{:authorization, "Bearer secret-token"}]
    }

    redacted = NatureWhistle.Notifier.Security.redact_metadata(metadata)

    assert redacted["apiKey"] == "[REDACTED]"
    assert redacted.request.customer_email == "[REDACTED]"
    assert redacted.request["account-id"] == "[REDACTED]"
    assert redacted.request.harmless == "visible"
    assert redacted.nested == [{:authorization, "[REDACTED]"}]
  end

  test "rejects whitespace-only atom metadata keys during validation" do
    Application.put_env(:nature_whistle, :sensitive_metadata_keys, [:"   "])

    assert_raise ArgumentError, ~r/:sensitive_metadata_keys/, fn ->
      NatureWhistle.Notifier.Security.validate_sensitive_metadata_keys!()
    end
  end

  test "validates sensitive metric event names" do
    Application.put_env(:nature_whistle, :sensitive_metrics, [[:billing, :customer, :balance]])
    assert :ok = NatureWhistle.Notifier.Security.validate_sensitive_metrics!()

    for invalid <- [:billing, [[]], [[:billing, "balance"]], [:billing, [:auth, :user]]] do
      Application.put_env(:nature_whistle, :sensitive_metrics, invalid)

      assert_raise ArgumentError, ~r/:sensitive_metrics/, fn ->
        NatureWhistle.Notifier.Security.validate_sensitive_metrics!()
      end
    end
  end

  test "redacts sensitive fields inside structs while preserving the struct type" do
    redacted =
      NatureWhistle.Notifier.Security.redact_metadata(%RuntimeError{
        message: "temporary failure",
        __exception__: true
      })

    assert %RuntimeError{} = redacted
    assert redacted.message == "temporary failure"
  end

  test "redacts sensitive measurement values before the custom value formatter runs", %{
    base_alert: base_alert
  } do
    test_pid = self()
    event = [:billing, :customer, :balance]
    Application.put_env(:nature_whistle, :sensitive_metrics, [event])

    alert = %{
      base_alert
      | event: event,
        formatter: fn value ->
          send(test_pid, {:formatter_received, value})
          "value=#{value}"
        end
    }

    log =
      capture_log(fn ->
        Notification.send_notification(alert, 123_456, %{}, :alert)
        Process.sleep(50)
      end)

    assert_receive {:formatter_received, "[REDACTED]"}
    assert log =~ "Alert template: value=[REDACTED]"
    refute log =~ "123456"
  end

  test "custom message formatter receives redacted metadata", %{base_alert: base_alert} do
    alert =
      Map.merge(base_alert, %{
        alert_message: "Alert: %{secret}",
        message_formatter: fn metadata -> %{secret: metadata.password} end
      })

    log =
      capture_log(fn ->
        Notification.send_notification(alert, 1, %{password: "do-not-leak"}, :alert)
        Process.sleep(50)
      end)

    assert log =~ "Alert: [REDACTED]"
    refute log =~ "do-not-leak"
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

  test "raises when a referenced notifier uses an unsupported service", %{
    base_alert: base_alert
  } do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :invalid_target, service: :invalid_target, config: %{}}
    ])

    alert = %{base_alert | notifiers: [:invalid_target]}

    assert_raise ArgumentError, fn ->
      NatureWhistle.Setup.check_notifier_config!([alert])
    end
  end

  test "raises when alert references a notifier missing from global config", %{
    base_alert: base_alert
  } do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :console, service: :console, config: %{}}
    ])

    alert = %{base_alert | notifiers: [:missing_channel]}

    assert_raise ArgumentError,
                 "Notifier config not found for :missing_channel",
                 fn ->
                   NatureWhistle.Setup.check_notifier_config!([alert])
                 end
  end

  test "raises when notifier profiles have duplicate names", %{base_alert: base_alert} do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :alerts, service: :console, config: %{}},
      %{name: :alerts, service: :webhook, config: %{webhook_url: "https://example.com"}}
    ])

    alert = %{base_alert | notifiers: [:alerts]}

    assert_raise ArgumentError, fn ->
      CheckNotifierConfig.validate_alert_notifiers!(alert)
      # NatureWhistle.Setup.validate_alert_notifier_service!([alert])
    end
  end

  test "accepts all supported notifier services", %{base_alert: base_alert} do
    services = [:console, :slack, :teams, :webhook]

    notifiers_config =
      Enum.map(services, fn service ->
        %{name: service, service: service, config: %{}}
      end)

    Application.put_env(:nature_whistle, :notifiers_config, notifiers_config)

    alert = %{base_alert | notifiers: services}

    assert :ok = NatureWhistle.Setup.check_notifier_config!([alert])
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
        config: %{
          webhook_url: "http://localhost:#{slack_bypass.port}",
          allow_insecure_http: true
        }
      },
      %{
        name: :teams_channel,
        service: :teams,
        config: %{
          webhook_url: "http://localhost:#{teams_bypass.port}",
          allow_insecure_http: true
        }
      },
      %{
        name: :webhook_channel,
        service: :webhook,
        config: [
          webhook_url: "http://localhost:#{webhook_bypass.port}",
          allow_insecure_http: true,
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

    Notification.send_notification(
      alert,
      "multi",
      %{source: :test, password: "do-not-send"},
      :alert
    )

    assert_receive {:slack_called, %{"text" => "Alert template: multi"}}, 500
    assert_receive {:teams_called, %{"text" => "Alert template: multi"}}, 500

    assert_receive {:webhook_called, "PUT", ["abc123"],
                    %{"severity" => "high", "text" => "Alert template: multi"}},
                   500
  end
end
