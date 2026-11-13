# File: test/nature_whistle/notifier/console_test.exs
defmodule NatureWhistle.Notifier.ConsoleTest do
  use ExUnit.Case, async: true

  alias NatureWhistle.Notifier.Console
  import ExUnit.CaptureLog

  test "deliver/3 logs output message using warning level" do
    log =
      capture_log(fn ->
        assert {:ok, :logged} = Console.deliver("Resource limit hit", %{}, %{})
      end)

    assert log =~ "[warning]"
    assert log =~ "[NatureWhistle] Resource limit hit"
  end

  test "deliver/3 does not log metadata by default" do
    log =
      capture_log(fn ->
        Console.deliver("Resource limit hit", %{password: "secret", cpu_index: 2}, %{})
      end)

    refute log =~ "Alert metadata"
    refute log =~ "secret"
  end

  test "deliver/3 redacts sensitive fields when metadata logging is enabled" do
    log =
      capture_log([level: :debug], fn ->
        Console.deliver(
          "Resource limit hit",
          %{password: "secret", nested: %{access_token: "token-value", cpu_index: 2}},
          %{include_metadata: true}
        )
      end)

    assert log =~ "Alert metadata"
    assert log =~ "[REDACTED]"
    assert log =~ "cpu_index: 2"
    refute log =~ "secret"
    refute log =~ "token-value"
  end
end
