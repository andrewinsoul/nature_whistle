ExUnit.start()

Application.ensure_all_started(:nature_whistle)

Application.put_env(:nature_whistle, :retry, [max_attempts: 1, base_delay_ms: 0])
