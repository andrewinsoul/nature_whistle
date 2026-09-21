defmodule NatureWhistle.Packs.Beam do
  @behaviour NatureWhistle.Pack

  @metrics [
    :memory,
    :process_memory,
    :ets_memory,
    :binary_memory,
    :process_count,
    :atom_count,
    :port_count,
    :run_queue
  ]

  @doc """
  Collects all BEAM metrics supported by the pack and emits their telemetry events.

  This is the convenience form used when all built-in BEAM metrics are desired.
  For the supervised collector, prefer `collect/1` so only the metrics required
  by active alerts are sampled.
  """
  def collect() do
    collect(@metrics)
  end

  @doc """
  Collects the requested BEAM runtime metrics and emits `:telemetry` events.

  Supported metric identifiers are `:memory`, `:process_memory`, `:ets_memory`,
  `:binary_memory`, `:process_count`, `:atom_count`, `:port_count`, and
  `:run_queue`.

  The emitted events use the `[:vm, ...]` event namespace consumed by the normal
  NatureWhistle alert pipeline. The function returns `:ok`.
  """
  def collect(metrics) do
    memory = :erlang.memory()

    if :memory in metrics do
      :telemetry.execute(
        [:vm, :memory, :total],
        %{total: memory[:total]},
        %{}
      )
    end

    if :process_memory in metrics do
      :telemetry.execute(
        [:vm, :memory, :processes],
        %{processes: memory[:processes]},
        %{}
      )
    end

    if :ets_memory in metrics do
      :telemetry.execute(
        [:vm, :memory, :ets],
        %{ets: memory[:ets]},
        %{}
      )
    end

    if :binary_memory in metrics do
      :telemetry.execute(
        [:vm, :memory, :binary],
        %{binary: memory[:binary]},
        %{}
      )
    end

    if :process_count in metrics do
      :telemetry.execute(
        [:vm, :processes, :count],
        %{count: :erlang.system_info(:process_count)},
        %{}
      )
    end

    if :atom_count in metrics do
      :telemetry.execute(
        [:vm, :atoms, :count],
        %{count: :erlang.system_info(:atom_count)},
        %{}
      )
    end

    if :port_count in metrics do
      :telemetry.execute(
        [:vm, :ports, :count],
        %{count: :erlang.system_info(:port_count)},
        %{}
      )
    end

    if :run_queue in metrics do
      :telemetry.execute(
        [:vm, :total_run_queue_lengths, :total],
        %{total: :erlang.statistics(:total_run_queue_lengths)},
        %{}
      )
    end

    :ok
  end

  @impl true
  @doc """
  Builds the built-in BEAM alert definitions.

  The optional `:thresholds` keyword list is keyed by metric name. A numeric
  value overrides that metric's default threshold, `false` disables the metric's
  alert, and an omitted metric keeps its default.

  The supported threshold keys are `:memory`, `:process_memory`, `:ets_memory`,
  `:binary_memory`, `:process_count`, `:atom_count`, `:port_count`, and
  `:run_queue`.
  """
  def alerts(opts) do
    thresholds =
      opts
      |> Keyword.get(:thresholds, [])
      |> Map.new()

    [
      %{
        id: :high_memory,
        event: [:vm, :memory, :total],
        threshold: 1_073_741_824,
        alert_message: "⚠️ High memory usage: %{value} MB",
        calm_message: "✅ Memory usage back to normal: %{value} MB",
        debounce_ms: 300_000,
        rate_limit: [
          window_ms: 60_000,
          max_events: 10
        ],
        notifier: :console
      },
      %{
        id: :high_cpu,
        event: [:vm, :total_run_queue_lengths, :total],
        threshold: 4,
        alert_message: "🚨 High CPU load: run queue length is %{value}",
        calm_message: "✅ CPU Queue length back to normal: %{value}",
        debounce_ms: 60_000,
        rate_limit: [
          window_ms: 60_000,
          max_events: 10
        ],
        sliding_window: [
          window_ms: 30_000,
          max_events: 3
        ],
        notifier: :console
      },
      %{
        id: :high_process_memory,
        event: [:vm, :memory, :processes],
        threshold: 536_870_912,
        alert_message: "⚠️ High process memory usage: %{value} MB",
        calm_message: "✅ Process memory usage back to normal: %{value} MB",
        debounce_ms: 300_000,
        notifier: :console
      },
      %{
        id: :high_ets_memory,
        event: [:vm, :memory, :ets],
        threshold: 268_435_456,
        alert_message: "⚠️ High ETS memory usage: %{value} MB",
        calm_message: "✅ ETS memory usage back to normal: %{value} MB",
        debounce_ms: 300_000,
        notifier: :console
      },
      %{
        id: :high_binary_memory,
        event: [:vm, :memory, :binary],
        threshold: 268_435_456,
        alert_message: "⚠️ High binary memory usage: %{value} MB",
        calm_message: "✅ Binary memory usage back to normal: %{value} MB",
        debounce_ms: 300_000,
        notifier: :console
      },
      %{
        id: :high_process_count,
        event: [:vm, :processes, :count],
        threshold: 50_000,
        alert_message: "⚠️ High process count: %{value}",
        calm_message: "✅ Process count back to normal: %{value}",
        debounce_ms: 300_000,
        notifier: :console
      },
      %{
        id: :high_atom_count,
        event: [:vm, :atoms, :count],
        threshold: 800_000,
        alert_message: "⚠️ High atom count: %{value}",
        calm_message: "✅ Atom count back to normal: %{value}",
        debounce_ms: 300_000,
        notifier: :console
      },
      %{
        id: :high_port_count,
        event: [:vm, :ports, :count],
        threshold: 5_000,
        alert_message: "⚠️ High port count: %{value}",
        calm_message: "✅ Port count back to normal: %{value}",
        debounce_ms: 300_000,
        notifier: :console
      }
    ]
    |> Enum.map(&configure_alert(&1, thresholds))
    |> Enum.reject(&is_nil/1)
  end

  defp configure_alert(alert, thresholds) do
    metric = metric_for_event(alert.event)

    case Map.get(thresholds, metric, :default) do
      false ->
        nil

      :default ->
        alert

      threshold when is_integer(threshold) ->
        %{alert | threshold: threshold}

      _ ->
        raise ArgumentError, "Invalid threshold value for #{metric}, must be an integer"
    end
  end

  @doc """
  Returns the BEAM metric identifiers required by a list of alert definitions.

  Metrics are derived from each alert's `[:vm, ...]` event and de-duplicated.
  The result is used by `NatureWhistle.Packs.Beam.Collector` so the runtime only
  samples metrics needed by active BEAM alerts.
  """
  def metrics(alerts) do
    Enum.map(alerts, &metric_for_event(&1.event))
    |> Enum.uniq()
  end

  defp metric_for_event([:vm, :memory, :total]), do: :memory
  defp metric_for_event([:vm, :memory, :processes]), do: :process_memory
  defp metric_for_event([:vm, :memory, :ets]), do: :ets_memory
  defp metric_for_event([:vm, :memory, :binary]), do: :binary_memory
  defp metric_for_event([:vm, :processes, :count]), do: :process_count
  defp metric_for_event([:vm, :atoms, :count]), do: :atom_count
  defp metric_for_event([:vm, :ports, :count]), do: :port_count
  defp metric_for_event([:vm, :total_run_queue_lengths, :total]), do: :run_queue
end
