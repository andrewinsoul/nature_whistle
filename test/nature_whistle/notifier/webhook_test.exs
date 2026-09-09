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
               method: :put,
               headers: [{"x-api-key", "abc123"}, {"origin", "nature-whistle"}],
               payload: %{severity: "high"}
             )
  end

  test "deliver/3 returns an error when the webhook endpoint fails", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, :max_attempts_exceeded} =
             Webhook.deliver("payload", %{}, webhook_url: "http://localhost:#{bypass.port}")
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
               %{webhook_url: "http://localhost:#{bypass.port}"}
             )
  end

  test "deliver/3 raises when configuration is invalid" do
    assert_raise BadMapError, fn ->
      Webhook.deliver("payload", %{}, :invalid_config)
    end
  end

  test "deliver/3 handles transport errors" do
    assert {:error, :max_attempts_exceeded} =
             Webhook.deliver(
               "payload",
               %{},
               %{webhook_url: "http://127.0.0.1:1"}
             )
  end
end
