defmodule NatureWhistle.Notifier.SlackTest do
  use ExUnit.Case

  test "sends message to Slack webhook" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Hello from nature_whistle"
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [webhook_url: "http://localhost:#{bypass.port}/"]

    assert {:ok, :sent} =
             NatureWhistle.Notifier.Slack.deliver("Hello from nature_whistle", %{}, config)
  end

  test "retries on failure" do
    bypass = Bypass.open()
    # First request fails, second succeeds
    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.resp(conn, 500, "Internal error")
    end)

    Bypass.expect(bypass, fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [webhook_url: "http://localhost:#{bypass.port}/"]
    # Retry is configured in test_helper with max_attempts: 1? We need to ensure retry is enabled.
    # But the retry helper is called inside Slack module. It uses the config from environment.
    # In test_helper we set max_attempts: 1, so no retry. For this test, we need to set higher.
    Application.put_env(:nature_whistle, :retry, max_attempts: 2, base_delay_ms: 10)
    assert {:ok, :sent} = NatureWhistle.Notifier.Slack.deliver("test", %{}, config)
  end

  test "exhausts retries on HTTP 400" do
    bypass = Bypass.open()
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 400, "Bad Request") end)
    config = [webhook_url: "http://localhost:#{bypass.port}/"]
    # The default retry config (3 attempts) will exhaust and return :max_attempts_exceeded
    assert {:error, :max_attempts_exceeded} =
             NatureWhistle.Notifier.Slack.deliver("test", %{}, config)
  end

  test "exhausts retries on HTTP 500" do
    bypass = Bypass.open()
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "Internal Error") end)
    config = [webhook_url: "http://localhost:#{bypass.port}/"]

    assert {:error, :max_attempts_exceeded} =
             NatureWhistle.Notifier.Slack.deliver("test", %{}, config)
  end
end
