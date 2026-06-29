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

  test "deliver/3 dumps diagnostic metadata to debug level logs if not empty" do
    log =
      capture_log(fn ->
        Console.deliver("Resource limit hit", %{cpu_index: 2}, %{})
      end)

    assert log =~ "Alert metadata: %{cpu_index: 2}"
  end
end
