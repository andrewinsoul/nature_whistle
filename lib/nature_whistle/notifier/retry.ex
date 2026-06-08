defmodule NatureWhistle.Notifier.Retry do
  @moduledoc """
  Retry helper for HTTP notifiers.
  Reads retry configuration from the host's config/config.exs.

  Example config:
      config :nature_whistle, retry: [
        max_attempts: 5,
        base_delay_ms: 1000,
        max_delay_ms: 30_000
      ]
  """

  @default_max_attempts 3
  @default_base_delay_ms 1000
  # 30 seconds
  @default_max_delay_ms 30_000

  @doc """
  Executes the given function, retrying on failure up to the configured max attempts.

  The function must return `{:ok, _}` or `{:error, _}`.
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
