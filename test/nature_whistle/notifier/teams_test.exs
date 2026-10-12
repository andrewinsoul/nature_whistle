defmodule NatureWhistle.Notifier.TeamsTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notifier.Teams

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

  test "deliver/3 posts a JSON payload to Teams using a minimal config", %{bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/"
      assert Jason.decode!(body) == %{"text" => "Teams Alert!"}

      Plug.Conn.resp(conn, 200, "ok")
    end)

    assert {:ok, :sent} =
             Teams.deliver("Teams Alert!", %{}, %{
               webhook_url: "http://localhost:#{bypass.port}",
               allow_insecure_http: true
             })
  end

  test "deliver/3 does not propagate a failure response body", %{bypass: bypass} do
    secret_response_body = "provider echoed secret-token-456"

    Bypass.expect_once(bypass, fn conn ->
      Plug.Conn.resp(conn, 500, secret_response_body)
    end)

    result =
      Teams.deliver("Teams Alert!", %{}, %{
        webhook_url: "http://localhost:#{bypass.port}",
        allow_insecure_http: true
      })

    assert result == {:error, :max_attempts_exceeded}
    refute inspect(result) =~ secret_response_body
  end
end
