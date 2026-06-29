defmodule NatureWhistle.EventGuard do
  @table :nature_whistle_rate_limit
  @sub_bucket_ms 10_000

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

  def record_sliding_window_event(alert, now) do
    bucket_timestamp = div(now, @sub_bucket_ms) * @sub_bucket_ms
    key = {{:sliding_window, alert.id}, bucket_timestamp}

    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end
end
