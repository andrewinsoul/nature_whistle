defmodule NatureWhistle.FailureTracker do
  @moduledoc """
  Aggregates repeated failures over a sliding time window.

  `FailureTracker` is a signal detector, not an alerting or notification
  system. It answers one question: has this failure key crossed the configured
  number of failures within the configured window?

  Once the threshold is crossed, the caller can promote the returned count into
  the normal NatureWhistle metric alert flow.

  The tracker deliberately treats the aggregation key as opaque. A pack can
  choose `{worker, queue}`, an endpoint, a process, or any other term that
  identifies the thing whose failures should be counted.
  """

  use GenServer
  require Logger

  @default_sweep_interval_ms 1_000

  defstruct failure_windows: %{},
            sweep_interval_ms: @default_sweep_interval_ms,
            recovery_handler: nil

  @doc """
  Starts the shared failure tracker.

  Options include:

  - `:name` to override the registered process name
  - `:sweep_interval_ms` to control automatic cleanup of expired failure windows
  - `:recovery_handler` as a one-argument function that receives
    `{alert_id, failure_key, other_active?}` entries after a sweep
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a failure for `key` and returns the current aggregate status.

  The aggregate is isolated by `alert_id` and `key`, allowing multiple packs
  and multiple aggregate rules to use the same tracker independently.

  ## Returns

  - `{:below_threshold, count}` when the current count is below the threshold
  - `{:triggered, count}` when the threshold has just been crossed
  - `{:active, count}` when the threshold was already crossed previously
  """
  def record_failure(
        alert_id,
        key,
        failures,
        within_ms,
        timestamp \\ System.monotonic_time(:millisecond)
      ) do
    validate_config!(failures, within_ms)

    GenServer.call(
      __MODULE__,
      {:record_failure, alert_id, key, failures, within_ms, timestamp}
    )
  end

  @doc """
  Manually sweeps expired failure windows.

  The optional `timestamp` argument is a monotonic timestamp in milliseconds,
  which is useful when deterministic cleanup is needed in tests or diagnostics.

  Returns a list of `{alert_id, failure_key}` entries whose active windows
  recovered during the sweep.
  """
  def sweep(timestamp \\ System.monotonic_time(:millisecond)) do
    GenServer.call(__MODULE__, {:sweep, timestamp})
  end

  @doc """
  Clears all tracked failure windows.

  Returns `:ok`. This is primarily useful for tests and operational reset
  scenarios where aggregate history should be discarded.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    recovery_handler = Keyword.get(opts, :recovery_handler)
    validate_sweep_interval!(sweep_interval_ms)
    validate_recovery_handler!(recovery_handler)
    schedule_sweep(sweep_interval_ms)

    {:ok,
     %__MODULE__{
       sweep_interval_ms: sweep_interval_ms,
       recovery_handler: recovery_handler
     }}
  end

  @impl true
  def handle_call(
        {:record_failure, alert_id, key, failures, within_ms, timestamp},
        _from,
        %__MODULE__{} = state
      ) do
    window_key = {alert_id, key}

    previous_window =
      Map.get(
        state.failure_windows,
        window_key,
        %{timestamps: [], active: false, within_ms: within_ms, threshold: failures}
      )

    timestamps =
      previous_window.timestamps
      |> prune_expired(timestamp, within_ms)
      |> Kernel.++([timestamp])

    count = length(timestamps)

    {status, active} =
      cond do
        count >= failures and not previous_window.active ->
          {{:triggered, count}, true}

        count >= failures ->
          {{:active, count}, true}

        true ->
          {{:below_threshold, count}, false}
      end

    failure_windows =
      Map.put(
        state.failure_windows,
        window_key,
        %{timestamps: timestamps, active: active, within_ms: within_ms, threshold: failures}
      )

    {:reply, status, %{state | failure_windows: failure_windows}}
  end

  @impl true
  def handle_call({:sweep, timestamp}, _from, %__MODULE__{} = state) do
    {failure_windows, recovered} = prune_windows(state.failure_windows, timestamp)
    recovered = Enum.reverse(recovered)
    notify_recoveries(recovered, failure_windows, state.recovery_handler)

    {:reply, recovered, %{state | failure_windows: failure_windows}}
  end

  @impl true
  def handle_call(:reset, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | failure_windows: %{}}}
  end

  @impl true
  def handle_info(:sweep, %__MODULE__{} = state) do
    {failure_windows, recovered} =
      prune_windows(state.failure_windows, System.monotonic_time(:millisecond))

    notify_recoveries(Enum.reverse(recovered), failure_windows, state.recovery_handler)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, %{state | failure_windows: failure_windows}}
  end

  defp prune_windows(failure_windows, timestamp) do
    Enum.reduce(failure_windows, {%{}, []}, fn {key, window}, {windows, recovered} ->
      timestamps = prune_expired(window.timestamps, timestamp, window.within_ms)
      count = length(timestamps)

      cond do
        count == 0 and window.active ->
          {windows, [key | recovered]}

        count == 0 ->
          {windows, recovered}

        count < window_threshold(window) and window.active ->
          updated_window = %{window | timestamps: timestamps, active: false}
          {Map.put(windows, key, updated_window), [key | recovered]}

        true ->
          {Map.put(windows, key, %{window | timestamps: timestamps}), recovered}
      end
    end)
  end

  # The threshold is part of the aggregate identity. Store it in the window
  # so automatic sweeps can recover state without external configuration.
  defp window_threshold(%{threshold: threshold}), do: threshold
  defp window_threshold(_window), do: 1

  defp prune_expired(timestamps, timestamp, within_ms) do
    cutoff = timestamp - within_ms
    Enum.drop_while(timestamps, &(&1 < cutoff))
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp notify_recoveries([], _failure_windows, _handler), do: :ok
  defp notify_recoveries(_recoveries, _failure_windows, nil), do: :ok

  defp notify_recoveries(recoveries, failure_windows, handler) when is_function(handler, 1) do
    Enum.each(recoveries, fn {alert_id, failure_key} ->
      other_active? =
        Enum.any?(failure_windows, fn
          {{^alert_id, _other_key}, %{active: true}} -> true
          _ -> false
        end)

      try do
        handler.({alert_id, failure_key, other_active?})
      rescue
        exception ->
          Logger.error("NatureWhistle aggregate recovery callback failed: #{inspect(exception)}")
      end
    end)
  end

  defp notify_recoveries(_recoveries, _failure_windows, _handler), do: :ok

  defp validate_config!(failures, within_ms) do
    unless is_integer(failures) and failures > 0 do
      raise ArgumentError, ":failures must be a positive integer"
    end

    unless is_integer(within_ms) and within_ms > 0 do
      raise ArgumentError, ":within_ms must be a positive integer"
    end
  end

  defp validate_sweep_interval!(interval_ms) do
    unless is_integer(interval_ms) and interval_ms > 0 do
      raise ArgumentError, ":sweep_interval_ms must be a positive integer"
    end
  end

  defp validate_recovery_handler!(nil), do: :ok

  defp validate_recovery_handler!(handler) when is_function(handler, 1), do: :ok

  defp validate_recovery_handler!(_handler) do
    raise ArgumentError, ":recovery_handler must be a one-argument function"
  end
end
