ExUnit.start()

case Application.ensure_all_started(:nature_whistle) do
  {:ok, _started_applications} ->
    :ok

  {:error, reason} ->
    raise "failed to start NatureWhistle for tests: #{inspect(reason)}"
end

# Application.put_env(:nature_whistle, :retry, max_attempts: 1, base_delay_ms: 0)
