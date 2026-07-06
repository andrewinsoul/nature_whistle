# File: test/nature_whistle/notifier/retry_test.exs
defmodule NatureWhistle.Notifier.RetryTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Notifier.Retry

  setup do
    original_retry = Application.get_env(:nature_whistle, :retry)

    on_exit(fn ->
      if original_retry,
        do: Application.put_env(:nature_whistle, :retry, original_retry),
        else: Application.delete_env(:nature_whistle, :retry)
    end)

    :ok
  end

  test "with_retry/1 returns ok result immediately when function execution succeeds" do
    assert {:ok, :success} = Retry.with_retry(fn -> {:ok, :success} end)
  end

  test "with_retry/1 retries until execution attempts run dry and drops max_attempts_exceeded error" do
    Application.put_env(:nature_whistle, :retry,
      max_attempts: 2,
      base_delay_ms: 1,
      max_delay_ms: 2
    )

    test_pid = self()

    {:error, :max_attempts_exceeded} =
      Retry.with_retry(fn ->
        send(test_pid, :executed)
        {:error, :failed}
      end)

    assert_receive :executed
    assert_receive :executed
    refute_receive :executed
  end
end
