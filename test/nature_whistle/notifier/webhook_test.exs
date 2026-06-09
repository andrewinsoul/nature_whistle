defmodule NatureWhistle.Notifier.WebhookTest do
  use ExUnit.Case

  test "simple body template" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      assert body == ~s({"text":"Hello"})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [url: "http://localhost:#{bypass.port}/", body_template: :simple]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("Hello", %{}, config)
  end

  test "full body template" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      assert body =~ ~s("text":"Hello")
      assert body =~ ~s("metadata":{})
      assert body =~ ~s("timestamp":)
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [url: "http://localhost:#{bypass.port}/", body_template: :full]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("Hello", %{}, config)
  end

  test "custom function body template" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      assert body == ~s({"custom":"Hello"})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    custom = fn msg, _ -> %{custom: msg} end
    config = [url: "http://localhost:#{bypass.port}/", body_template: custom]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("Hello", %{}, config)
  end

  test "uses custom HTTP method" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      assert conn.method == "PUT"
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [url: "http://localhost:#{bypass.port}/", method: :put]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("test", %{}, config)
  end

  test "includes custom headers" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      assert {"x-custom", "value"} in conn.req_headers
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [url: "http://localhost:#{bypass.port}/", headers: [{"x-custom", "value"}]]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("test", %{}, config)
  end

  test "uses fallback body template for unknown value" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      assert body == ~s({"text":"test"})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    config = [url: "http://localhost:#{bypass.port}/", body_template: :invalid]
    assert {:ok, :sent} = NatureWhistle.Notifier.Webhook.deliver("test", %{}, config)
  end
end
