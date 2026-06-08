defmodule NatureWhistle.Notifier.RetryTest do
  use ExUnit.Case

  test "retries on error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fun = fn ->
      count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

      case count do
        0 -> {:error, :fail}
        1 -> {:ok, :success}
        _ -> {:error, :unexpected}
      end
    end

    Application.put_env(:nature_whistle, :retry, max_attempts: 2, base_delay_ms: 1)
    assert {:ok, :success} = NatureWhistle.Notifier.Retry.with_retry(fun)
    Agent.stop(counter)
  end

  test "returns error after max attempts" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fun = fn ->
      Agent.update(counter, &(&1 + 1))
      {:error, :always_fail}
    end

    Application.put_env(:nature_whistle, :retry, max_attempts: 3, base_delay_ms: 1)
    assert {:error, :max_attempts_exceeded} = NatureWhistle.Notifier.Retry.with_retry(fun)
    count = Agent.get(counter, & &1)
    assert count == 3
    Agent.stop(counter)
  end
end
