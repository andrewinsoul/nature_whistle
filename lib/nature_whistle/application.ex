defmodule NatureWhistle.Application do
  @moduledoc """
  The OTP application entry point for `nature_whistle`.

  This module is responsible for:

  - Creating ETS tables (`:nature_whistle_alerts`, `:nature_whistle_notifiers`, `:nature_whistle_alert_state`, `:nature_whistle_cooldown`)
  - Loading alert and notifier configuration from the host application’s environment
  - Attaching `:telemetry` handlers for every configured event

  To start `nature_whistle` in your host application, add `NatureWhistle.Application` to your supervision tree:

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

  All configuration is read from the `:nature_whistle` application environment.
  See the main `NatureWhistle` module documentation or the README for detailed configuration examples.

  ## Fault tolerance

  If the `NatureWhistle.Application` process terminates, the host’s supervisor restarts it,
  recreating all ETS tables and re‑attaching telemetry handlers. No persistent state is lost.
  """

  use Application

  @impl true
  def start(_type, _args) do
    cpu_cores = System.schedulers_online()

    create_ets_tables()
    load_config_into_ets(cpu_cores)
    attach_handlers()

    {:ok, self()}
  end

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

    if :ets.whereis(:nature_whistle_notifiers) == :undefined do
      :ets.new(:nature_whistle_notifiers, [
        :named_table,
        :set,
        :public,
        write_concurrency: true,
        read_concurrency: true
      ])
    end

    if :ets.whereis(:nature_whistle_cooldown) == :undefined do
      :ets.new(:nature_whistle_cooldown, [:named_table, :set, :public])
    end

    if :ets.whereis(:nature_whistle_alert_state) == :undefined do
      :ets.new(:nature_whistle_alert_state, [:named_table, :set, :public])
    end
  end

  def load_config_into_ets(cpu_cores) do
    :ets.delete_all_objects(:nature_whistle_alerts)
    :ets.delete_all_objects(:nature_whistle_notifiers)
    :ets.delete_all_objects(:nature_whistle_alert_state)

    alerts = Application.get_env(:nature_whistle, :alerts, :default)
    notifiers = Application.get_env(:nature_whistle, :notifiers, :default)

    alerts_list = if alerts == :default, do: default_alerts(), else: alerts
    notifiers_list = if notifiers == :default, do: default_notifiers(), else: notifiers

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
          alert_message:
            Map.get(alert, :alert_message) ||
              Map.get(alert, :message) ||
              "🚨 NatureWhistle alert: %{value} exceeded threshold (#{raw_threshold}) for event #{inspect(event)}",
          calm_message:
            Map.get(
              alert,
              :calm_message,
              "✅ NatureWhistle resolution: %{value} is back below threshold (#{raw_threshold}) for event #{inspect(event)}"
            ),
          cooldown_ms: Map.get(alert, :cooldown_ms, 60_000),
          resolution_ms: Map.get(alert, :resolution_ms, 60_000),
          notifier: Map.get(alert, :notifier, :console)
        }

        Map.update(acc, event, [alert_map], &[alert_map | &1])
      end)

    for {event, alert_list} <- alerts_by_event do
      :ets.insert(:nature_whistle_alerts, {event, alert_list})
    end

    for {name, opts} <- notifiers_list do
      :ets.insert(:nature_whistle_notifiers, {name, opts})
    end
  end

  # defp load_config_into_ets(cpu_cores) do
  #   :ets.delete_all_objects(:nature_whistle_alerts)
  #   :ets.delete_all_objects(:nature_whistle_notifiers)
  #   :ets.delete_all_objects(:nature_whistle_alert_state)
  #   alerts = Application.get_env(:nature_whistle, :alerts, :default)
  #   notifiers = Application.get_env(:nature_whistle, :notifiers, :default)
  #   alerts_list = if alerts == :default, do: default_alerts(), else: alerts
  #   notifiers_list = if notifiers == :default, do: default_notifiers(), else: notifiers
  #   Enum.reduce(alerts_list, %{}, fn alert, acc ->
  #     event = Keyword.fetch!(alert, :event)
  #     raw_threshold = Keyword.fetch!(alert, :threshold)
  #     threshold_value =
  #       if event == [:vm, :total_run_queue_lengths, :total] do
  #         raw_threshold * cpu_cores
  #       else
  #         raw_threshold
  #       end
  #     IO.inspect(alert, label: "Nature mapping >>>>>>>>>>>>>>>>>>>>>>>>>>>>>")
  #     alert_map = %{
  #       id: Keyword.fetch!(alert, :id),
  #       event: Keyword.fetch!(alert, :event),
  #       measurement_key: Keyword.get(alert, :measurement_key, :value),
  #       threshold: threshold_value,
  #       alert_message:
  #         Keyword.get(
  #           alert,
  #           :alert_message,
  #           "🚨 NatureWhistle alert: %{value} exceeded threshold (#{alert.threshold}) for event #{inspect(event)}"
  #         ),
  #       calm_message:
  #         Keyword.get(
  #           alert,
  #           :calm_message,
  #           "✅ NatureWhistle resolution: %{value} is back below threshold (#{alert.threshold}) for event #{inspect(event)}"
  #         ),
  #       cooldown_ms: Keyword.get(alert, :cooldown_ms, 60_000),
  #       resolution_ms: Keyword.get(alert, :resolution_ms, 60_000),
  #       notifier: Keyword.get(alert, :notifier, :console)
  #     }
  #     IO.puts(7_677_677_666_776)
  #     Map.update(acc, event, [alert_map], &[alert_map | &1])
  #   end)
  #   |> IO.inspect(label: "KKKKKKKKKK")
  #   |> Enum.each(fn {event, alert_list} ->
  #     :ets.insert(:nature_whistle_alerts, {event, alert_list})
  #   end)
  #   notifiers_list
  #   |> Enum.each(fn {name, opts} ->
  #     :ets.insert(:nature_whistle_notifiers, {name, opts})
  #   end)
  # end

  defp default_alerts do
    [
      [
        id: :high_memory,
        event: [:vm, :memory, :total],
        # 1 GB
        threshold: 1_073_741_824,
        alert_message: "⚠️ High memory usage: %{value} MB",
        calm_message: "✅ Memory usage back to normal: %{value} MB",
        # 5 minutes
        cooldown_ms: 300_000,
        notifier: :console
      ],
      [
        id: :high_cpu,
        event: [:vm, :total_run_queue_lengths, :total],
        threshold: 4,
        alert_message: "🚨 High CPU load: run queue length is %{value}",
        calm_message: "✅ CPU Queue length back to normal: %{value}",
        # 1 minute
        cooldown_ms: 60_000,
        notifier: :console
      ]
    ]
  end

  defp default_notifiers do
    [
      console: []
    ]
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
end
