defmodule NatureWhistle.BackgroundCleaner do
  @moduledoc """
  A background worker that periodically sweeps the `:nature_whistle_rate_limit`
  table to prune expired sliding window time-buckets and prevent memory leaks.
  """

  use GenServer
  require Logger
  import NatureWhistle.Notification

  @table :nature_whistle_rate_limit
  @state_table :nature_whistle_alert_state
  @default_sweep_interval_ms :timer.minutes(5)
  @default_max_window_history_ms :timer.hours(1)

  def start_link(opts) do
    {name, server_opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, server_opts, name: name)
  end

  def start_debounce(alert_id, resolution_ms, value, metadata) do
    GenServer.cast(__MODULE__, {:start_debounce, alert_id, resolution_ms, value, metadata})
  end

  def extend_debounce(alert_id, resolution_ms, value, metadata) do
    GenServer.cast(__MODULE__, {:extend_debounce, alert_id, resolution_ms, value, metadata})
  end

  @impl true
  def init(opts) do
    sweep_interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)

    max_history =
      Application.get_env(:nature_whistle, :max_window_history_ms, @default_max_window_history_ms)

    schedule_sweep(sweep_interval)
    {:ok, %{sweep_interval_ms: sweep_interval, max_window_history_ms: max_history, timers: %{}}}
  end

  @impl true
  def handle_cast({:start_debounce, alert_id, resolution_ms, healthy_value, metadata}, state) do
    timer_ref = Process.send_after(self(), {:resolve_alert, alert_id}, resolution_ms)

    new_timers =
      Map.put(state.timers, alert_id, %{ref: timer_ref, value: healthy_value, metadata: metadata})

    {:noreply, %{state | timers: new_timers}}
  end

  @impl true
  def handle_cast({:extend_debounce, alert_id, resolution_ms, new_bad_value, metadata}, state) do
    if old_timer = Map.get(state.timers, alert_id) do
      Process.cancel_timer(old_timer.ref)
    end

    new_timer_ref = Process.send_after(self(), {:resolve_alert, alert_id}, resolution_ms)

    new_timers =
      Map.put(state.timers, alert_id, %{
        ref: new_timer_ref,
        value: new_bad_value,
        metadata: metadata
      })

    {:noreply, %{state | timers: new_timers}}
  end

  @impl true
  def handle_info({:resolve_alert, alert_id}, state) do
    :ets.delete(@state_table, alert_id)

    {alert_timer_data, new_timers} = Map.pop(state.timers, alert_id)

    if alert = NatureWhistle.get_alert_config(alert_id) do
      value = alert_timer_data.value
      metadata = alert_timer_data.metadata

      send_notification(alert, value, metadata, :calm)
    end

    {:noreply, %{state | timers: new_timers}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      prune_expired_buckets(state.max_window_history_ms)
    rescue
      e -> Logger.error("NatureWhistle BackgroundCleaner sweep failed: #{inspect(e)}")
    end

    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  def prune_expired_buckets(max_window_history_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff_time = now - max_window_history_ms

    match_spec = [
      {
        {{{:sliding_window, :"$1"}, :"$2"}, :_},
        [{:<, :"$2", cutoff_time}],
        [true]
      }
    ]

    :ets.select_delete(@table, match_spec)

    sweep_rate_limits(cutoff_time)
  end

  defp sweep_rate_limits(cutoff_time) do
    match_spec = [{{{:rate_limit, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    :ets.select(@table, match_spec)
    |> Enum.each(fn {id, timestamps} ->
      valid_timestamps = Enum.filter(timestamps, &(&1 >= cutoff_time))

      if valid_timestamps == [] do
        :ets.delete(@table, {:rate_limit, id})
      else
        :ets.insert(@table, {{:rate_limit, id}, valid_timestamps})
      end
    end)
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
