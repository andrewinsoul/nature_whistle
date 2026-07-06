defmodule NatureWhistle.EventGuard do
  @moduledoc """
  Rate-limit and sliding-window helpers for NatureWhistle.

  The event handler delegates all traffic-shaping decisions to this module so
  the logic is easy to test in isolation. Two independent filters are exposed:

  - `rate_limit` limits the number of alert dispatches over a time window
  - `sliding_window` counts breach density across fixed-size buckets

  Both helpers read and write to the `:nature_whistle_rate_limit` ETS table.
  """

  @table :nature_whistle_rate_limit
  @sub_bucket_ms 10_000

  @doc """
  Returns `true` when the alert is still under its rate-limit allowance.

  The alert configuration may include a `rate_limit` keyword list with:

  - `:window_ms` - the lookback window used for counting recent events
  - `:max_events` - the number of events allowed within that window

  When no rate limit is configured, the function always returns `true`.
  """
  def allow_rate_limit?(alert, now) do
    case Map.get(alert, :rate_limit) do
      config when is_list(config) ->
        window = Keyword.fetch!(config, :window_ms)
        max_events = Keyword.fetch!(config, :max_events)
        cutoff_time = now - window

        timestamps =
          case :ets.lookup(@table, {:rate_limit, alert.id}) do
            [{_key, list}] -> list
            [] -> []
          end

        valid_count = Enum.count(timestamps, fn ts -> ts >= cutoff_time end)
        valid_count < max_events

      nil ->
        true
    end
  end

  @doc """
  Records a rate-limit timestamp for the given alert.

  The timestamps are stored newest-first so the cleanup pass can trim old data
  efficiently while still keeping the implementation straightforward.
  """
  def record_rate_limit(%{id: id}, now) do
    key = {:rate_limit, id}

    timestamps =
      case :ets.lookup(@table, key) do
        [{_key, timestamps}] -> timestamps
        [] -> []
      end

    :ets.insert(
      @table,
      {key, [now | timestamps]}
    )
  end

  @doc """
  Returns `true` when the alert has already reached its sliding-window cap.

  The sliding-window gate uses coarse buckets of `@sub_bucket_ms` milliseconds.
  This keeps the ETS state compact while still approximating the configured
  density window closely enough for alerting purposes.
  """
  def allow_sliding_window?(alert, now) do
    case Map.get(alert, :sliding_window) do
      config when is_list(config) ->
        window_ms = Keyword.fetch!(config, :window_ms)
        max_events = Keyword.fetch!(config, :max_events)
        cutoff_time = now - window_ms

        match_spec = [
          {
            {{{:sliding_window, alert.id}, :"$1"}, :"$2"},
            [{:>=, :"$1", div(cutoff_time, @sub_bucket_ms) * @sub_bucket_ms}],
            [:"$2"]
          }
        ]

        current_total = @table |> :ets.select(match_spec) |> Enum.sum()
        current_total >= max_events

      nil ->
        false
    end
  end

  @doc """
  Increments the sliding-window bucket for the alert at the current timestamp.

  Buckets are stored in ETS as `{ {:sliding_window, alert_id}, bucket_start_ms }`
  entries whose counters are incremented atomically.
  """
  def record_sliding_window_event(alert, now) do
    bucket_timestamp = div(now, @sub_bucket_ms) * @sub_bucket_ms
    key = {{:sliding_window, alert.id}, bucket_timestamp}

    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end
end
