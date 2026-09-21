defmodule NatureWhistle.Packs.Oban do
  @moduledoc """
  Alert definitions for the real Oban job telemetry contract.

  This pack is a telemetry consumer. It does not depend on or start Oban. The
  application must include Oban separately; when Oban emits its standard job
  events, NatureWhistle can evaluate the generated alerts:

    * `[:oban, :job, :stop]` for completed-job duration and queue-time alerts
    * `[:oban, :job, :exception]` for job-failure and repeated-failure alerts

  Oban reports `:duration` and `:queue_time` in native time units. Pack options
  accept thresholds in milliseconds and convert them to native units before
  building alert definitions.

  The exception alert correlates a failed job using `{job_id, worker, queue}`.
  A matching `:stop` event with `state: :success` is treated as the recovery
  signal for the calm notification. Slow-job and slow-queue alerts currently
  listen to `:stop`; they do not apply
  those thresholds to failed `:exception` events.
  """

  @behaviour NatureWhistle.Pack

  @job_events %{
    stop: [:oban, :job, :stop],
    exception: [:oban, :job, :exception]
  }

  @alerts [
    {:slow_job, :stop, :duration, 5_000},
    {:slow_queue, :stop, :queue_time, 1_000},
    {:job_exception, :exception}
  ]

  @impl true
  @doc """
  Builds Oban alert definitions from the supplied pack options.

  Supported options include:

  - `:thresholds` - keyword list for `:slow_job` and `:slow_queue`; values are
    milliseconds and `false` disables the corresponding alert
  - `:failure_detection` - enables repeated job-failure aggregation when set
    to a keyword list; `:failures` defaults to `10` and `:within_ms` defaults to
    `300_000`

  The pack also includes an event alert for job exceptions.
  """
  def alerts(opts) do
    thresholds = Keyword.get(opts, :thresholds, [])

    metric_alerts =
      Enum.flat_map(@alerts, fn
        {alert_name, _event_name, _measurement, default} = alert ->
          case Keyword.get(thresholds, alert_name, default) do
            false -> []
            threshold_ms -> [build_metric_alert(alert, threshold_ms)]
          end

        {:job_exception, :exception} ->
          [build_event_alert(:job_exception, :exception)]
      end)

    aggregate_alerts =
      case Keyword.get(opts, :failure_detection, false) do
        false -> []
        config -> [build_failure_alert(config)]
      end

    metric_alerts ++ aggregate_alerts
  end

  @doc false
  def failure_key(metadata) do
    job = Map.get(metadata, :job, %{})

    id = Map.get(job, :id, Map.get(job, "id"))
    worker = Map.get(job, :worker, Map.get(job, "worker"))
    queue = Map.get(job, :queue, Map.get(job, "queue"))

    {id, worker, queue}
  end

  defp build_metric_alert(
         {alert_name, event_name, measurement, _default_threshold_ms},
         threshold_ms
       ) do
    %{
      id: :"nature_whistle_oban_#{alert_name}",
      event: @job_events[event_name],
      condition: :metric,
      measurement_key: measurement,
      threshold: System.convert_time_unit(threshold_ms, :millisecond, :native),
      alert_message: "🚨 Oban #{alert_name} breached: %{value}",
      calm_message: "✅ Oban #{alert_name} recovered: %{value}"
    }
  end

  @doc false
  def notification_metadata(metadata) do
    job = Map.get(metadata, :job, %{})

    %{
      job_id: Map.get(job, :id, Map.get(job, "id")),
      worker: Map.get(job, :worker, Map.get(job, "worker")),
      queue: Map.get(job, :queue, Map.get(job, "queue"))
    }
  end

  defp build_event_alert(:job_exception, :exception) do
    %{
      id: :nature_whistle_oban_job_exception,
      event: @job_events.exception,
      condition: :event,
      correlation: %{
        key: &__MODULE__.failure_key/1,
        recovery_event: @job_events.stop,
        recovery?: &__MODULE__.successful_stop?/1
      },
      message_formatter: &__MODULE__.notification_metadata/1,
      event_value: 1,
      alert_message: "🚨 Oban job %{job_id} failed — %{worker} on queue %{queue}",
      calm_message: "✅ Oban job %{job_id} recovered — %{worker} on queue %{queue}"
    }
  end

  @doc false
  def successful_stop?(metadata) do
    Map.get(metadata, :state) == :success
  end

  defp build_failure_alert(config) do
    failures = Keyword.get(config, :failures, 10)
    within_ms = Keyword.get(config, :within_ms, 300_000)

    %{
      id: :nature_whistle_oban_repeated_job_failures,
      event: @job_events.exception,
      condition:
        {:aggregate,
         [
           key: &__MODULE__.failure_key/1,
           failures: failures,
           within_ms: within_ms,
           measurement_key: :failure_count
         ]},
      threshold: failures,
      measurement_key: :failure_count,
      alert_message: "🚨 Oban repeated job failures: %{value}",
      calm_message: "✅ Oban repeated job failures recovered: %{value}"
    }
  end
end
