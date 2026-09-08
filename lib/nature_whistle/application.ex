defmodule NatureWhistle.Application do
  @moduledoc """
  OTP bootstrap for NatureWhistle.

  This application module owns the runtime setup for the library:

  - it creates the ETS tables used to store alert definitions, alert state,
    and rate-limiting data
  - it loads alert configuration from the `:nature_whistle` application
    environment into ETS
  - it attaches a telemetry handler for each unique configured or runtime-registered event and tracks those handlers in ETS.
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

    if :ets.whereis(:nature_whistle_correlation_state) == :undefined do
      :ets.new(:nature_whistle_correlation_state, [:named_table, :set, :public])
    end

    if :ets.whereis(:nature_whistle_telemetry_handlers) == :undefined do
      :ets.new(:nature_whistle_telemetry_handlers, [
        :named_table,
        :set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end
  end

  @doc """
  Normalizes application alert configuration and stores it in ETS.

  `schedulers_online` is used to scale the default CPU run-queue alert so the threshold
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
  def load_config_into_ets(schedulers_online) do
    :ets.delete_all_objects(:nature_whistle_alerts)
    :ets.delete_all_objects(:nature_whistle_alert_state)
    :ets.delete_all_objects(:nature_whistle_rate_limit)
    :ets.delete_all_objects(:nature_whistle_correlation_state)

    alerts = Application.get_env(:nature_whistle, :alerts, :default)

    alerts_list = if alerts == :default, do: NatureWhistle.default_alerts(), else: alerts
    alerts_list = alerts_list ++ load_pack_alerts()

    alerts_list = Enum.map(alerts_list, &normalize_alert!(&1, schedulers_online))

    validate_unique_alert_ids!(alerts_list)

    alerts_by_event =
      Enum.reduce(alerts_list, %{}, fn alert, acc ->
        Map.update(acc, alert.event, [alert], &[alert | &1])
      end)

    for {event, alert_list} <- alerts_by_event do
      :ets.insert(:nature_whistle_alerts, {event, alert_list})
    end
  end

  @doc """
  Registers an alert in the running NatureWhistle instance.

  Runtime alerts are kept in ETS and are therefore intentionally ephemeral:
  they are available immediately but are not persisted across a BEAM restart.
  """
  def register_alert(alert) when is_map(alert) or is_list(alert) do
    if :ets.whereis(:nature_whistle_alerts) == :undefined do
      {:error, :not_started}
    else
      do_register_alert(alert)
    end
  end

  def register_alert(_alert), do: {:error, :invalid_alert}

  defp do_register_alert(alert) do
    alert = normalize_alert!(alert, System.schedulers_online())

    if alert_id_exists?(alert.id) do
      {:error, :already_registered}
    else
      event_alerts =
        case :ets.lookup(:nature_whistle_alerts, alert.event) do
          [{_event, alerts}] -> [alert | alerts]
          [] -> [alert]
        end

      :ets.insert(:nature_whistle_alerts, {alert.event, event_alerts})
      sync_telemetry_handlers()
      {:ok, alert}
    end
  end

  @doc """
  Removes an alert from the running NatureWhistle instance.
  """
  def unregister_alert(alert_id) do
    case remove_alert_from_ets(alert_id) do
      {:ok, _alert} ->
        sync_telemetry_handlers()
        :ok

      :error ->
        {:error, :not_found}
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

  defp alert_id_exists?(alert_id) do
    :ets.foldl(
      fn {_event, alerts}, found ->
        found or Enum.any?(alerts, &(&1.id == alert_id))
      end,
      false,
      :nature_whistle_alerts
    )
  end

  defp remove_alert_from_ets(alert_id) do
    case :ets.tab2list(:nature_whistle_alerts)
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
          :ets.lookup_element(:nature_whistle_alerts, event, 2)
          |> Enum.reject(&(&1.id == alert_id))

        if remaining == [] do
          :ets.delete(:nature_whistle_alerts, event)
        else
          :ets.insert(:nature_whistle_alerts, {event, remaining})
        end

        :ets.delete(:nature_whistle_alert_state, alert_id)
        :ets.delete(:nature_whistle_rate_limit, {:rate_limit, alert_id})
        :ets.match_delete(:nature_whistle_rate_limit, {{:sliding_window, alert_id}, :_})
        :ets.match_delete(:nature_whistle_correlation_state, {{alert_id, :_}, :_})

        {:ok, alert}
    end
  end

  defp sync_telemetry_handlers() do
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
        :nature_whistle_alerts
      )
      |> Enum.uniq()

    current_events =
      :ets.tab2list(:nature_whistle_telemetry_handlers)
      |> Enum.map(fn {event, handler_id} -> {event, handler_id} end)

    desired_event_set = MapSet.new(desired_events)

    Enum.each(desired_events, fn event ->
      case :ets.lookup(:nature_whistle_telemetry_handlers, event) do
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
              :ets.insert(
                :nature_whistle_telemetry_handlers,
                {event, handler_id}
              )

            {:error, :already_exists} ->
              :ets.insert(
                :nature_whistle_telemetry_handlers,
                {event, handler_id}
              )
          end
      end
    end)

    Enum.each(current_events, fn {event, handler_id} ->
      unless MapSet.member?(desired_event_set, event) do
        :telemetry.detach(handler_id)
        :ets.delete(:nature_whistle_telemetry_handlers, event)
      end
    end)

    :ok
  end

  defp validate_unique_alert_ids!(alerts) do
    ids = Enum.map(alerts, fn alert -> Map.get(alert, :id) end)

    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "duplicate NatureWhistle alert ids: #{inspect(Enum.uniq(duplicates))}"
    end
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
    sync_telemetry_handlers()
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
    schedulers_online = System.schedulers_online()
    create_ets_tables()
    load_config_into_ets(schedulers_online)
    attach_handlers()

    sweep_interval = Application.get_env(:nature_whistle, :background_sweep_interval_ms, 10_000)

    cleaner_opts =
      if sweep_interval && is_integer(sweep_interval),
        do: [sweep_interval_ms: sweep_interval],
        else: []

    validate_retry_config!()

    children = [
      {Task.Supervisor, name: NatureWhistle.TaskSupervisor},
      {NatureWhistle.FailureTracker, []},
      {NatureWhistle.BackgroundCleaner, cleaner_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NatureWhistle.Supervisor)
  end
end
