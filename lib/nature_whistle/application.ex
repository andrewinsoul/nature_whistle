defmodule NatureWhistle.Application do
  @moduledoc """
  OTP bootstrap for NatureWhistle.

  This application module owns the runtime setup for the library:

  - it creates the ETS tables used to store alert definitions, alert state,
    and rate-limiting data
  - it loads alert configuration from the `:nature_whistle` application
    environment into ETS
  - it attaches a telemetry handler for each unique configured event
  - it starts the `NatureWhistle.TaskSupervisor` used for asynchronous
    notification delivery
  - it starts `NatureWhistle.BackgroundCleaner`, which resolves alert timers
    and prunes old rate-limit data

  The module is intentionally small, but it is the most important piece of the
  runtime because every other module depends on these ETS tables and processes
  existing before the first telemetry event is handled.
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

  @doc """
  Normalizes application alert configuration and stores it in ETS.

  `cpu_cores` is used to scale the default CPU run-queue alert so the threshold
  remains proportional to the size of the current scheduler pool.

  The loader accepts alerts written as keyword lists or maps. Each alert is
  converted into a normalized map that contains the keys used by the runtime:

  - `:id`
  - `:event`
  - `:measurement_key`
  - `:threshold`
  - `:formatter`
  - `:alert_message`
  - `:calm_message`
  - `:debounce_ms`
  - `:resolution_ms`
  - `:sliding_window`
  - `:rate_limit`
  - `:notifiers`

  For compatibility, the loader also accepts the older singular `:notifier`
  key and promotes it to the `:notifiers` list used by the dispatcher.

  The normalized alerts are grouped by telemetry event and written into the
  `:nature_whistle_alerts` table. Existing table contents are cleared first so
  the result reflects the current application configuration exactly.
  """
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
          notifiers: Map.get(alert, :notifiers, List.wrap(Map.get(alert, :notifier, [:console])))
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

  @doc """
  Creates the application runtime.

  The startup sequence is:

  1. create the ETS tables if they do not already exist
  2. load alert definitions from application config into ETS
  3. attach one telemetry handler per configured event
  4. validate retry settings
  5. start the task supervisor and background cleaner

  The function returns the result of the internal supervisor start-up.
  """
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
