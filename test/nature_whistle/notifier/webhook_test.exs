defmodule NatureWhistle.Notifier.WebhookTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notifier.Webhook

  setup do
    bypass = Bypass.open()
    original_retry = Application.get_env(:nature_whistle, :retry)

    Application.put_env(:nature_whistle, :retry,
      max_attempts: 1,
      base_delay_ms: 0,
      max_delay_ms: 1
    )

    on_exit(fn ->
      if original_retry do
        Application.put_env(:nature_whistle, :retry, original_retry)
      else
        Application.delete_env(:nature_whistle, :retry)
      end
    end)

    {:ok, bypass: bypass}
  end

  test "deliver/3 sends custom methods, headers and JSON payloads", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "PUT"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["abc123"]
      assert Plug.Conn.get_req_header(conn, "origin") == ["nature-whistle"]
      assert Jason.decode!(body) == %{"text" => "payload", "severity" => "high"}

      Plug.Conn.resp(conn, 200, "ok")
    end)

    assert {:ok, :sent} =
             Webhook.deliver(
               "payload",
               %{},
               webhook_url: "http://localhost:#{bypass.port}",
               allow_insecure_http: true,
               method: :put,
               headers: [{"x-api-key", "abc123"}, {"origin", "nature-whistle"}],
               payload: %{severity: "high"}
             )
  end

  test "deliver/3 does not expose a webhook response body when the endpoint fails", %{
    bypass: bypass
  } do
    secret_response_body = "provider echoed secret-token-123"

    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.resp(conn, 500, secret_response_body)
    end)

    result =
      Webhook.deliver("payload", %{},
        webhook_url: "http://localhost:#{bypass.port}",
        allow_insecure_http: true
      )

    assert result == {:error, :max_attempts_exceeded}
    refute inspect(result) =~ secret_response_body
  end

  test "deliver/3 accepts map configuration and uses defaults", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "POST"
      assert Jason.decode!(body) == %{"text" => "payload"}

      Plug.Conn.resp(conn, 200, "ok")
    end)

    assert {:ok, :sent} =
             Webhook.deliver(
               "payload",
               %{},
               %{webhook_url: "http://localhost:#{bypass.port}", allow_insecure_http: true}
             )
  end

  test "deliver/3 raises when configuration is invalid" do
    assert_raise BadMapError, fn ->
      Webhook.deliver("payload", %{}, :invalid_config)
    end
  end

  test "deliver/3 rejects insecure HTTP URLs by default", %{bypass: bypass} do
    assert {:error, :insecure_webhook_url} =
             Webhook.deliver("payload", %{}, webhook_url: "http://localhost:#{bypass.port}")
  end

  test "deliver/3 handles transport errors" do
    assert {:error, :max_attempts_exceeded} =
             Webhook.deliver(
               "payload",
               %{},
               %{webhook_url: "http://127.0.0.1:1", allow_insecure_http: true}
             )
  end
end
