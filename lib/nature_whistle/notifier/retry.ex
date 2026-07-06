defmodule NatureWhistle.Notifier.Retry do
  @moduledoc """
  Exponential backoff helper used by HTTP delivery modules.

  `Slack`, `Teams`, and `Webhook` all delegate request retries to this module
  so the retry policy is implemented in one place.

  The retry policy is configured under `:nature_whistle, :retry` and supports:

  - `:max_attempts` - how many total attempts should be made
  - `:base_delay_ms` - the first wait period before a retry
  - `:max_delay_ms` - the maximum sleep used when backoff grows

  If the function supplied to `with_retry/1` keeps failing, the helper returns
  `{:error, :max_attempts_exceeded}` after the final attempt.
  """

  @default_max_attempts 3
  @default_base_delay_ms 1000
  @default_max_delay_ms 30_000

  @doc """
  Executes `fun` with retry and exponential backoff.

  The callback must return either:

  - `{:ok, value}` to stop retrying and return success immediately
  - `{:error, reason}` to trigger a retry until the attempt budget is exhausted

  The delay starts at `base_delay_ms`, doubles after each failed attempt, and is
  capped by `max_delay_ms`.
  """
  def with_retry(fun) do
    max_attempts = max_attempts()
    base_delay = base_delay_ms()
    max_delay = max_delay_ms()

    do_retry(fun, max_attempts, base_delay, max_delay)
  end

  defp do_retry(_fun, 0, _delay, _max_delay), do: {:error, :max_attempts_exceeded}

  defp do_retry(fun, attempts, delay, max_delay) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _reason} ->
        # Wait but don't exceed max_delay
        actual_delay = min(delay, max_delay)
        Process.sleep(actual_delay)
        # Next delay still doubles, but will be capped again
        do_retry(fun, attempts - 1, delay * 2, max_delay)
    end
  end

  # Configuration readers
  defp max_attempts do
    get_retry_config(:max_attempts, @default_max_attempts)
  end

  defp base_delay_ms do
    get_retry_config(:base_delay_ms, @default_base_delay_ms)
  end

  defp max_delay_ms do
    get_retry_config(:max_delay_ms, @default_max_delay_ms)
  end

  defp get_retry_config(key, default) do
    Application.get_env(:nature_whistle, :retry, [])
    |> Keyword.get(key, default)
  end
end
