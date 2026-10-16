ExUnit.start()

case NatureWhistle.Supervisor.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  {:error, reason} -> raise "failed to start NatureWhistle for tests: #{inspect(reason)}"
end

# Application.put_env(:nature_whistle, :retry, max_attempts: 1, base_delay_ms: 0)
