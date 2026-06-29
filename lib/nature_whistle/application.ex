defmodule NatureWhistle.Application do
  @moduledoc """
  The OTP application entry point for `nature_whistle`.

  This module is responsible for setting up the core in-memory table structures,
  loading alert rules, attaching telemetry event handlers, and managing the package's
  internal supervision tree for asynchronous and resilient operations.

  Specifically, it handles:
  - **ETS Table Initialization:** Creates named, public storage tables (`:nature_whistle_alerts`,
    `:nature_whistle_alert_state`, `:nature_whistle_debounce`,
    and `:nature_whistle_rate_limit`). Note that `:nature_whistle_rate_limit` is built
    as an `:ordered_set` to support high-performance atomic updates for sliding window time-buckets.
  - **Configuration Parsing:** Automatically ingests alert and notifier profiles from the host
    application's environment variables.
  - **Telemetry Hooking:** Dynamically attaches `:telemetry` execution handlers for every
    configured system event during runtime boot.
  - **Resilient Process Supervision:** Spins up a supervised architecture consisting of a
    `Task.Supervisor` (to offload notifier webhooks asynchronously away from the emitting application threads)
    and a `NatureWhistle.BackgroundCleaner` process (to periodically clear out expired sliding window metrics).

  ## Supervision Setup

  To start `nature_whistle` in your host application, append `NatureWhistle.Application`
  to your main supervisor tree block:

      # lib/my_app/application.ex
      def start(_type, _args) do
        children = [
          MyApp.Repo,
          MyAppWeb.Endpoint,
          NatureWhistle.Application   # <-- add this line
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Configuration

  All global settings are read from the `:nature_whistle` application environment.
  You can customize the sweeping behavior of the background cleaner by modifying the setting below:

      config :nature_whistle,
        background_sweep_interval_ms: :timer.minutes(5)

  For complex alert definitions (including sliding windows, debouncing intervals, and rate limits),
  see the main `NatureWhistle` module documentation or the README.md file.

  ## Fault Tolerance & Core Isolation

  If the `NatureWhistle.Application` supervisor process terminates or crashes unexpectedly,
  the host application's supervisor will automatically restart it. Upon recreation, all underlying
  ETS tables are safely remade, global handlers are re-attached to the active telemetry dispatch pipeline,
  and background processes are fresh-booted.
  """

  use Application

  defp create_ets_tables do
    if :ets.whereis(:nature_whistle_alerts) == :undefined do
      :ets.new(:nature_whistle_alerts, [
        :named_table,
        :set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    if :ets.whereis(:nature_whistle_rate_limit) == :undefined do
      :ets.new(:nature_whistle_rate_limit, [
        :named_table,
        :ordered_set,
        :public,
        write_concurrency: :auto,
        read_concurrency: true
      ])
    end

    if :ets.whereis(:nature_whistle_alert_state) == :undefined do
      :ets.new(:nature_whistle_alert_state, [:named_table, :set, :public])
    end
  end

  def load_config_into_ets(cpu_cores) do
    :ets.delete_all_objects(:nature_whistle_alerts)
    :ets.delete_all_objects(:nature_whistle_alert_state)
    :ets.delete_all_objects(:nature_whistle_rate_limit)

    alerts = Application.get_env(:nature_whistle, :alerts, :default)

    alerts_list = if alerts == :default, do: NatureWhistle.default_alerts(), else: alerts

    # Convert all alerts to maps (works for keyword lists and maps)
    alerts_list =
      Enum.map(alerts_list, fn alert ->
        if is_list(alert), do: Map.new(alert), else: alert
      end)

    alerts_by_event =
      Enum.reduce(alerts_list, %{}, fn alert, acc ->
        event = Map.fetch!(alert, :event)
        raw_threshold = Map.fetch!(alert, :threshold)

        threshold_value =
          if event == [:vm, :total_run_queue_lengths, :total] do
            raw_threshold * cpu_cores
          else
            raw_threshold
          end

        alert_map = %{
          id: Map.fetch!(alert, :id),
          event: event,
          measurement_key: Map.get(alert, :measurement_key, :value),
          threshold: threshold_value,
          formatter: Map.get(alert, :formatter),
          alert_message:
            Map.get(
              alert,
              :alert_message,
              "🚨 NatureWhistle alert: %{value} exceeded threshold (#{raw_threshold}) for event #{inspect(event)}"
            ),
          calm_message:
            Map.get(
              alert,
              :calm_message,
              "✅ NatureWhistle resolution: %{value} is back below threshold (#{raw_threshold}) for event #{inspect(event)}"
            ),
          debounce_ms: Map.get(alert, :debounce_ms, 60_000),
          resolution_ms: Map.get(alert, :resolution_ms, 60_000),
          sliding_window: Map.get(alert, :sliding_window),
          rate_limit: Map.get(alert, :rate_limit),
          notifiers: Map.get(alert, :notifiers, [])
        }

        Map.update(acc, event, [alert_map], &[alert_map | &1])
      end)

    for {event, alert_list} <- alerts_by_event do
      :ets.insert(:nature_whistle_alerts, {event, alert_list})
    end
  end

  defp validate_retry_config! do
    retry_config = Application.get_env(:nature_whistle, :retry, [])
    base_delay = Keyword.get(retry_config, :base_delay_ms, 1000)
    max_delay = Keyword.get(retry_config, :max_delay_ms, 30_000)

    if base_delay > max_delay do
      raise RuntimeError, """
      ❌ NatureWhistle Configuration Error:
         The value of :max_delay_ms (#{max_delay}ms) must be greater than :base_delay_ms (#{base_delay}ms).
         Please update your config/config.exs settings.
      """
    end
  end

  defp attach_handlers do
    :ets.foldl(
      fn {event, _alerts}, acc ->
        [event | acc]
      end,
      [],
      :nature_whistle_alerts
    )
    |> Enum.uniq()
    |> Enum.each(fn event ->
      :telemetry.attach(
        "nature_whistle:#{inspect(event)}",
        event,
        &NatureWhistle.EventHandler.handle_event/4,
        nil
      )
    end)
  end

  @impl true
  def start(_type, _args) do
    cpu_cores = System.schedulers_online()
    create_ets_tables()
    load_config_into_ets(cpu_cores)
    attach_handlers()

    sweep_interval = Application.get_env(:nature_whistle, :background_sweep_interval_ms, 10_000)

    cleaner_opts =
      if sweep_interval && is_integer(sweep_interval),
        do: [sweep_interval_ms: sweep_interval],
        else: []

    validate_retry_config!()

    children = [
      {Task.Supervisor, name: NatureWhistle.TaskSupervisor},
      {NatureWhistle.BackgroundCleaner, cleaner_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NatureWhistle.Supervisor)
  end
end
