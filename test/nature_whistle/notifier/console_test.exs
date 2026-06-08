defmodule NatureWhistle.Notifier.ConsoleTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  test "delivers message via Logger.warning" do
    log = capture_log(fn ->
      assert {:ok, :logged} = NatureWhistle.Notifier.Console.deliver("test message", %{}, [])
    end)
    assert log =~ "[warning] [NatureWhistle] test message"
  end
end
