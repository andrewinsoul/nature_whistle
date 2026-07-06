defmodule NatureWhistle.TestHelpers do
  @moduledoc """
  Shared assertion helpers for asynchronous testing inside NatureWhistle.
  """
  import ExUnit.Assertions

  @doc """
  Repeatedly evaluates an assertion function until it passes or hits the retry limit.
  Useful for checking asynchronous side-effects like ETS state changes or GenServer states.
  """
  def assert_eventually(assertion_fun, retries \\ 10, delay_ms \\ 15) do
    if assertion_fun.() do
      true
    else
      if retries > 0 do
        Process.sleep(delay_ms)
        assert_eventually(assertion_fun, retries - 1, delay_ms)
      else
        assert assertion_fun.()
      end
    end
  end
end
