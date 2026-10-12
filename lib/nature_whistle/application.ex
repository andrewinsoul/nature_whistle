defmodule NatureWhistle.Application do
  @moduledoc """
  OTP bootstrap for NatureWhistle.

  `NatureWhistle.Setup` owns NatureWhistle's ETS state, alert configuration,
  telemetry-handler wiring, runtime alert operations, and collector lifecycle.
  It also supplies the optional supervised mailbox monitor child.
  """

  use Application

  defdelegate load_config_into_ets(schedulers_online), to: NatureWhistle.Setup
  defdelegate register_alert(alert), to: NatureWhistle.Setup
  defdelegate unregister_alert(alert_id), to: NatureWhistle.Setup

  @impl true
  def start(_type, _args) do
    beam_metrics = NatureWhistle.Setup.init()
    NatureWhistle.Setup.validate_retry_config!()

    sweep_interval = Application.get_env(:nature_whistle, :background_sweep_interval_ms, 10_000)

    beam_metrics_interval_ms =
      Application.get_env(:nature_whistle, :beam_metric_interval_ms, 5_000)

    cleaner_opts =
      if sweep_interval && is_integer(sweep_interval),
        do: [sweep_interval_ms: sweep_interval],
        else: []

    beam_collector_children =
      if beam_metrics == [] do
        []
      else
        [
          {NatureWhistle.Packs.Beam.Collector,
           [interval_ms: beam_metrics_interval_ms, metrics: beam_metrics]}
        ]
      end

    children =
      [
        {Task.Supervisor, name: NatureWhistle.TaskSupervisor},
        {NatureWhistle.FailureTracker,
         [recovery_handler: &NatureWhistle.EventHandler.handle_aggregate_recovery/1]}
      ] ++
        beam_collector_children ++
        NatureWhistle.Setup.mailbox_monitor_children() ++
        [{NatureWhistle.BackgroundCleaner, cleaner_opts}]

    {:ok, pid} =
      Supervisor.start_link(children, strategy: :one_for_one, name: NatureWhistle.Supervisor)

    {:ok, pid}
  end
end
