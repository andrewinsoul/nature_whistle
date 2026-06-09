defmodule NatureWhistle.Notifier.TeamsTest do
  use ExUnit.Case

  test "sends message to Teams webhook" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      assert body =~ "Hello Teams"
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [webhook_url: "http://localhost:#{bypass.port}/"]
    assert {:ok, :sent} = NatureWhistle.Notifier.Teams.deliver("Hello Teams", %{}, config)
  end

  test "retries on failure" do
    bypass = Bypass.open()
    Bypass.expect_once(bypass, fn conn -> Plug.Conn.resp(conn, 500, "error") end)
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
    config = [webhook_url: "http://localhost:#{bypass.port}/"]
    Application.put_env(:nature_whistle, :retry, max_attempts: 2, base_delay_ms: 10)
    assert {:ok, :sent} = NatureWhistle.Notifier.Teams.deliver("test", %{}, config)
  end

  test "exhausts retries on HTTP 400" do
    bypass = Bypass.open()
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 400, "Bad Request") end)
    config = [webhook_url: "http://localhost:#{bypass.port}/"]
    # The default retry config (3 attempts) will exhaust and return :max_attempts_exceeded
    assert {:error, :max_attempts_exceeded} =
             NatureWhistle.Notifier.Teams.deliver("test", %{}, config)
  end

  test "exhausts retries on HTTP 500" do
    bypass = Bypass.open()
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 500, "Internal Error") end)
    config = [webhook_url: "http://localhost:#{bypass.port}/"]

    assert {:error, :max_attempts_exceeded} =
             NatureWhistle.Notifier.Teams.deliver("test", %{}, config)
  end
end
