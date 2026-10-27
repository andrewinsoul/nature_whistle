defmodule NatureWhistle.Setup do
  @moduledoc """
  Runtime setup for NatureWhistle.

  This module owns the state and event wiring required before the application
  supervision tree starts:

  - creates the ETS tables used by NatureWhistle
  - loads and normalizes configured alerts
  - attaches telemetry handlers for configured and runtime alert events
  - registers and removes runtime alerts
  - synchronizes the BEAM collector with the active runtime alerts
  - validates retry configuration

  `NatureWhistle.Application` remains responsible only for OTP supervision
  startup and child specification assembly.
  """
  alias NatureWhistle.Notifier
  alias NatureWhistle.Util.CheckNotifierConfig

  @alerts_table :nature_whistle_alerts
  @alert_state_table :nature_whistle_alert_state
  @rate_limit_table :nature_whistle_rate_limit
  @correlation_state_table :nature_whistle_correlation_state
  @telemetry_handlers_table :nature_whistle_telemetry_handlers
  @supported_notification_channels [:console, :webhook, :teams, :slack]

  @doc """
  Builds the child specifications for the host-supervised NatureWhistle runtime.

  Runtime state is initialized before children start. The host application owns
  the lifecycle by adding `NatureWhistle.Supervisor` to its supervision tree.
  """
  def child_specs do
    beam_metrics = init()
    validate_retry_config!()

    sweep_interval =
      Application.get_env(:nature_whistle, :background_sweep_interval_ms, 10_000)

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

    [
      {Task.Supervisor, name: NatureWhistle.TaskSupervisor},
      {NatureWhistle.FailureTracker,
       [recovery_handler: &NatureWhistle.EventHandler.handle_aggregate_recovery/1]}
    ] ++
      beam_collector_children ++
      mailbox_monitor_children() ++
      [{NatureWhistle.BackgroundCleaner, cleaner_opts}]
  end

  @doc """
  Initializes NatureWhistle's ETS state, alert configuration, and telemetry
  handlers.

  Returns the BEAM metric identifiers required by the loaded alerts. The
  supervisor uses this result to decide whether to start the BEAM collector.
  """
  def init do
    Notifier.Security.validate_sensitive_metadata_keys!()
    Notifier.Security.validate_sensitive_metrics!()

    create_ets_tables()
    beam_metrics = load_config_into_ets(System.schedulers_online())
    sync_telemetry_handlers()

    beam_metrics
  end

  defp create_ets_tables do
    if :ets.whereis(@alerts_table) == :undefined do
      :ets.new(@alerts_table, [
        :named_table,
        :set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    if :ets.whereis(@rate_limit_table) == :undefined do
      :ets.new(@rate_limit_table, [
        :named_table,
        :ordered_set,
        :public,
        write_concurrency: :auto,
        read_concurrency: true
      ])
    end

    if :ets.whereis(@alert_state_table) == :undefined do
      :ets.new(@alert_state_table, [:named_table, :set, :public])
    end

    if :ets.whereis(@correlation_state_table) == :undefined do
      :ets.new(@correlation_state_table, [:named_table, :set, :public])
    end

    if :ets.whereis(@telemetry_handlers_table) == :undefined do
      :ets.new(@telemetry_handlers_table, [
        :named_table,
        :set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    :ok
  end

  @doc """
  Normalizes application alert configuration and stores it in ETS.

  `schedulers_online` is used to scale the default CPU run-queue alert so the
  threshold remains proportional to the size of the current scheduler pool.
  """
  def load_config_into_ets(schedulers_online) do
    :ets.delete_all_objects(@alerts_table)
    :ets.delete_all_objects(@alert_state_table)
    :ets.delete_all_objects(@rate_limit_table)
    :ets.delete_all_objects(@correlation_state_table)

    alerts = Application.get_env(:nature_whistle, :alerts, :default)

    alerts_list =
      if alerts == :default do
        NatureWhistle.Packs.Beam.alerts([])
      else
        alerts
      end

    alerts_list = alerts_list ++ load_pack_alerts()
    alerts_list = Enum.map(alerts_list, &normalize_alert!(&1, schedulers_online))

    validate_unique_alert_ids!(alerts_list)
    validate_alert_notifier_service!(alerts_list)

    alerts_by_event =
      Enum.reduce(alerts_list, %{}, fn alert, acc ->
        Map.update(acc, alert.event, [alert], &[alert | &1])
      end)

    for {event, alert_list} <- alerts_by_event do
      :ets.insert(@alerts_table, {event, alert_list})
    end

    alerts_list
    |> Enum.filter(&match?([:vm | _], &1.event))
    |> NatureWhistle.Packs.Beam.metrics()
  end

  @doc """
  Synchronizes telemetry handlers with the alert events currently in ETS.

  This is called during startup and after runtime alert registration or removal.
  """
  def sync_telemetry_handlers do
    desired_events =
      :ets.foldl(
        fn {_event, alerts}, acc ->
          Enum.reduce(alerts, acc, fn alert, events ->
            case Map.get(alert, :correlation) do
              %{recovery_event: recovery_event} ->
                [recovery_event, alert.event | events]

              _ ->
                [alert.event | events]
            end
          end)
        end,
        [],
        @alerts_table
      )
      |> Enum.uniq()

    current_events = :ets.tab2list(@telemetry_handlers_table)
    desired_event_set = MapSet.new(desired_events)

    Enum.each(desired_events, fn event ->
      case :ets.lookup(@telemetry_handlers_table, event) do
        [{^event, _handler_id}] ->
          :ok

        [] ->
          handler_id = "nature_whistle:#{inspect(event)}"

          case :telemetry.attach(
                 handler_id,
                 event,
                 &NatureWhistle.EventHandler.handle_event/4,
                 nil
               ) do
            :ok ->
              :ets.insert(@telemetry_handlers_table, {event, handler_id})

            {:error, :already_exists} ->
              :ets.insert(@telemetry_handlers_table, {event, handler_id})
          end
      end
    end)

    Enum.each(current_events, fn {event, handler_id} ->
      unless MapSet.member?(desired_event_set, event) do
        :telemetry.detach(handler_id)
        :ets.delete(@telemetry_handlers_table, event)
      end
    end)

    :ok
  end

  @doc """
  Registers an alert in the running NatureWhistle instance.

  Runtime alerts are kept in ETS and are therefore intentionally ephemeral:
  they are available immediately but are not persisted across a BEAM restart.
  """
  def register_alert(alert) when is_map(alert) or is_list(alert) do
    if :ets.whereis(@alerts_table) == :undefined do
      {:error, :not_started}
    else
      do_register_alert(alert)
    end
  end

  def register_alert(_alert), do: {:error, :invalid_alert}

  @doc """
  Removes an alert from the running NatureWhistle instance.

  Returns `:ok` when the alert exists and is removed, or
  `{:error, :not_found}` when no matching alert is registered.
  """
  def unregister_alert(alert_id) do
    case remove_alert_from_ets(alert_id) do
      {:ok, _alert} ->
        sync_telemetry_handlers()
        sync_beam_collector()
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the mailbox monitor child when mailbox monitoring is explicitly enabled.

  Mailbox monitoring is opt-in and disabled unless `:mailbox_monitor` has
  `enabled: true`. The `:enabled` key is consumed here and the remaining
  options are passed to `NatureWhistle.MailboxMonitor`.
  """
  def mailbox_monitor_children do
    config = Application.get_env(:nature_whistle, :mailbox_monitor, [])
    config = if is_map(config), do: Map.to_list(config), else: config

    if is_list(config) and Keyword.get(config, :enabled, false) and
         Keyword.get(config, :mode, :own) != :disabled do
      [{NatureWhistle.MailboxMonitor, config}]
    else
      []
    end
  end

  @doc false
  def validate_retry_config! do
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

  defp default_notifiers do
    [
      %{
        name: :console,
        service: :console,
        config: nil
      }
    ]
  end

  def check_notifier_config!(alert_list) do
    notifiers_config =
      Application.get_env(:nature_whistle, :notifiers_config, default_notifiers())

    Enum.each(alert_list, fn alert ->
      alert_notifiers = Map.get(alert, :notifiers, [:console])

      allowed_notifier_config_targets =
        CheckNotifierConfig.validate_notifier_config!(alert_notifiers, notifiers_config)

      Enum.each(allowed_notifier_config_targets, fn notifier_config ->
        if notifier_config.service not in @supported_notification_channels do
          raise ArgumentError,
                "Notifier profile #{inspect(Map.get(notifier_config, :name))} uses an unsupported service: #{inspect(notifier_config.service)}"
        end
      end)
    end)
  end

  @doc false
  def sync_beam_collector do
    beam_metrics =
      :ets.tab2list(@alerts_table)
      |> Enum.flat_map(fn {_event, alerts} -> alerts end)
      |> Enum.filter(&match?([:vm | _], &1.event))
      |> NatureWhistle.Packs.Beam.metrics()

    interval_ms = Application.get_env(:nature_whistle, :beam_metric_interval_ms, 5_000)
    collector = NatureWhistle.Packs.Beam.Collector
    supervisor = NatureWhistle.Supervisor

    case {beam_metrics, Process.whereis(collector)} do
      {[], nil} ->
        :ok

      {[], _pid} ->
        :ok = Supervisor.terminate_child(supervisor, collector)
        Supervisor.delete_child(supervisor, collector)

      {metrics, nil} ->
        {:ok, _pid} =
          Supervisor.start_child(
            supervisor,
            {collector, [interval_ms: interval_ms, metrics: metrics]}
          )

        :ok

      {metrics, _pid} ->
        collector.configure(metrics)
    end
  end

  @doc false
  defp normalize_alert!(alert, schedulers_online) do
    alert = if is_list(alert), do: Map.new(alert), else: alert
    id = Map.fetch!(alert, :id)
    event = Map.fetch!(alert, :event)
    condition = Map.get(alert, :condition, :metric)

    {measurement_key, threshold_value, message_threshold} =
      normalize_condition!(alert, condition, event, schedulers_online)

    %{
      id: id,
      event: event,
      condition: condition,
      measurement_key: measurement_key,
      threshold: threshold_value,
      formatter: Map.get(alert, :formatter),
      alert_message:
        Map.get(
          alert,
          :alert_message,
          default_alert_message(condition, event, message_threshold)
        ),
      calm_message:
        Map.get(
          alert,
          :calm_message,
          default_calm_message(condition, event, message_threshold)
        ),
      debounce_ms: Map.get(alert, :debounce_ms, 60_000),
      resolution_ms: Map.get(alert, :resolution_ms, 60_000),
      sliding_window: Map.get(alert, :sliding_window),
      rate_limit: Map.get(alert, :rate_limit),
      notifiers: Map.get(alert, :notifiers, List.wrap(Map.get(alert, :notifier, [:console]))),
      event_value: Map.get(alert, :event_value, 1),
      aggregate: aggregate_config(condition),
      correlation: Map.get(alert, :correlation),
      message_formatter: Map.get(alert, :message_formatter)
    }
  end

  defp do_register_alert(alert) do
    alert = normalize_alert!(alert, System.schedulers_online())

    if alert_id_exists?(alert.id) do
      {:error, :already_registered}
    else
      # glory
      CheckNotifierConfig.validate_duplicate_alert_notifier!()
      alert_notifiers = Map.get(alert, :notifiers, [:console])

      notifiers_config =
        Application.get_env(:nature_whistle, :notifiers_config, default_notifiers())

      allowed_notifier_config_targets =
        CheckNotifierConfig.validate_notifier_config!(alert_notifiers, notifiers_config)

      Enum.each(allowed_notifier_config_targets, fn notifier_config ->
        if notifier_config.service not in @supported_notification_channels do
          raise ArgumentError,
                "Notifier profile #{inspect(Map.get(notifier_config, :name))} uses an unsupported service: #{inspect(notifier_config.service)}"
        end
      end)

      event_alerts =
        case :ets.lookup(@alerts_table, alert.event) do
          [{_event, alerts}] -> [alert | alerts]
          [] -> [alert]
        end

      :ets.insert(@alerts_table, {alert.event, event_alerts})
      sync_telemetry_handlers()
      sync_beam_collector()
      {:ok, alert}
    end
  end

  defp alert_id_exists?(alert_id) do
    :ets.foldl(
      fn {_event, alerts}, found ->
        found or Enum.any?(alerts, &(&1.id == alert_id))
      end,
      false,
      @alerts_table
    )
  end

  defp remove_alert_from_ets(alert_id) do
    case :ets.tab2list(@alerts_table)
         |> Enum.find_value(fn {event, alerts} ->
           case Enum.find(alerts, &(&1.id == alert_id)) do
             nil -> nil
             alert -> {event, alert}
           end
         end) do
      nil ->
        :error

      {event, alert} ->
        remaining =
          :ets.lookup_element(@alerts_table, event, 2)
          |> Enum.reject(&(&1.id == alert_id))

        if remaining == [] do
          :ets.delete(@alerts_table, event)
        else
          :ets.insert(@alerts_table, {event, remaining})
        end

        :ets.delete(@alert_state_table, alert_id)
        :ets.delete(@rate_limit_table, {:rate_limit, alert_id})
        :ets.match_delete(@rate_limit_table, {{:sliding_window, alert_id}, :_})
        :ets.match_delete(@correlation_state_table, {{alert_id, :_}, :_})

        {:ok, alert}
    end
  end

  defp load_pack_alerts do
    Application.get_env(:nature_whistle, :packs, [])
    |> Enum.flat_map(fn
      {pack, opts} ->
        pack_module!(pack).alerts(opts)

      pack when is_atom(pack) ->
        pack_module!(pack).alerts([])
    end)
  end

  defp pack_module!(name) when is_atom(name) do
    if Code.ensure_loaded?(name) and function_exported?(name, :alerts, 1) do
      name
    else
      resolve_named_pack!(name)
    end
  end

  defp pack_module!(name) when is_binary(name), do: resolve_named_pack!(name)

  defp resolve_named_pack!(name) do
    module = Module.concat(NatureWhistle.Packs, Macro.camelize(to_string(name)))

    unless Code.ensure_loaded?(module) and function_exported?(module, :alerts, 1) do
      raise ArgumentError, "NatureWhistle pack #{inspect(name)} is not available"
    end

    module
  end

  defp validate_unique_alert_ids!(alerts) do
    ids = Enum.map(alerts, &Map.get(&1, :id))

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "duplicate NatureWhistle alert ids: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp validate_alert_notifier_service!(alerts) do
    CheckNotifierConfig.validate_duplicate_alert_notifier!()
    check_notifier_config!(alerts)
  end

  defp normalize_condition!(alert, :metric, event, schedulers_online) do
    raw_threshold = Map.fetch!(alert, :threshold)

    threshold_value =
      if event == [:vm, :total_run_queue_lengths, :total] do
        raw_threshold * schedulers_online
      else
        raw_threshold
      end

    {Map.get(alert, :measurement_key, :value), threshold_value, raw_threshold}
  end

  defp normalize_condition!(alert, :event, _event, _cpu_cores) do
    {Map.get(alert, :measurement_key), nil, nil}
  end

  defp normalize_condition!(_alert, {:aggregate, aggregate}, _event, _cpu_cores) do
    threshold = Keyword.fetch!(aggregate, :failures)
    measurement_key = Keyword.get(aggregate, :measurement_key, :failure_count)
    {measurement_key, threshold, threshold}
  end

  defp normalize_condition!(_alert, condition, _event, _cpu_cores) do
    raise ArgumentError, "unsupported NatureWhistle alert condition: #{inspect(condition)}"
  end

  defp aggregate_config({:aggregate, aggregate}), do: aggregate
  defp aggregate_config(_condition), do: nil

  defp default_alert_message(:event, event, _threshold),
    do: "🚨 NatureWhistle event alert: #{inspect(event)} occurred"

  defp default_alert_message(_condition, event, threshold),
    do:
      "🚨 NatureWhistle alert: %{value} exceeded threshold (#{threshold}) for event #{inspect(event)}"

  defp default_calm_message(:event, event, _threshold),
    do: "✅ NatureWhistle event alert resolved: #{inspect(event)} is no longer occurring"

  defp default_calm_message(_condition, event, threshold),
    do:
      "✅ NatureWhistle resolution: %{value} is back below threshold (#{threshold}) for event #{inspect(event)}"
end
