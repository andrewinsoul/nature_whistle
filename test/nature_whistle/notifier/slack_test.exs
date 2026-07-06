defmodule NatureWhistle.Notifier.SlackTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notifier.Slack

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

  test "deliver/3 posts a JSON payload to Slack using a minimal config", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/"
      assert Jason.decode!(body) == %{"text" => "Slack Alert!"}

      Plug.Conn.resp(conn, 200, "ok")
    end)

    assert {:ok, :sent} =
             Slack.deliver("Slack Alert!", %{}, %{webhook_url: "http://localhost:#{bypass.port}"})
  end

  test "deliver/3 returns an error when Slack responds with a failure status", %{
    bypass: bypass
  } do
    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, :max_attempts_exceeded} =
             Slack.deliver("Slack Alert!", %{}, %{webhook_url: "http://localhost:#{bypass.port}"})
  end
end
