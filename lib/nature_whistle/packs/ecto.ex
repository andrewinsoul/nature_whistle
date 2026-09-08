defmodule NatureWhistle.Packs.Ecto do
  @behaviour NatureWhistle.Pack

  @alert_metrics [
    {:slow_query, :query, :total_time, 1_000},
    {:slow_queue, :query, :queue_time, 100},
    {:slow_db_execution, :query, :query_time, 500},
    {:slow_decode, :query, :decode_time, 100},
    {:slow_encode, :query, :encode_time, 100}
  ]

  @impl true
  @doc """
  Builds Ecto alert definitions for the configured repository.

  Required option:

  - `:repo` - the Ecto repository module whose telemetry configuration is used

  Optional option:

  - `:thresholds` - keyword list keyed by alert name, with thresholds in
    milliseconds; use `false` to disable an alert

  The generated thresholds are converted from milliseconds to the native
  time unit used by Ecto telemetry measurements.
  """
  def alerts(opts) do
    repo = Keyword.fetch!(opts, :repo)
    repo_config = repo.config()
    otp_app = Keyword.fetch!(repo_config, :otp_app)

    telemetry_prefix =
      Keyword.get(
        repo_config,
        :telemetry_prefix,
        [otp_app, :repo]
      )

    thresholds = Keyword.get(opts, :thresholds, [])

    Enum.flat_map(
      @alert_metrics,
      fn {alert_name, _event_name, _measurement, default_threshold_ms} = alert ->
        case Keyword.get(thresholds, alert_name, default_threshold_ms) do
          false ->
            []

          threshold_ms ->
            [
              build_alert(
                alert,
                otp_app,
                telemetry_prefix,
                threshold_ms
              )
            ]
        end
      end
    )
  end

  defp build_alert(
         {alert_name, event_name, measurement, _default_threshold_ms},
         otp_app,
         telemetry_prefix,
         threshold_ms
       ) do
    threshold =
      System.convert_time_unit(
        threshold_ms,
        :millisecond,
        :native
      )

    %{
      id: :"nature_whistle_ecto_#{otp_app}_#{alert_name}",
      event: telemetry_prefix ++ [event_name],
      measurement_key: measurement,
      threshold: threshold
    }
  end
end
