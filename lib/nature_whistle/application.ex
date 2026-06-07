defmodule NatureWhistle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    create_ets_tables()
    load_config_into_ets()
    attach_handlers()

    children = [
      # Starts a worker by calling: NatureWhistle.Worker.start_link(arg)
      # {NatureWhistle.Worker, arg}
      NatureWhistle.Cooldown
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NatureWhistle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp create_ets_tables do
    if :ets.whereis(:nature_whistle_alerts) == :undefined do
      :ets.new(:nature_whistle_alerts, [:named_table, :set, read_concurrency: true])
    end

    if :ets.whereis(:nature_whistle_notifiers) == :undefined do
      :ets.new(:nature_whistle_notifiers, [:named_table, :set, read_concurrency: true])
    end

    if :ets.whereis(:nature_whistle_cooldown) == :undefined do
      :ets.new(:nature_whistle_cooldown, [:named_table, :set, public: true])
    end
  end

  defp load_config_into_ets do
    :ets.delete_all_objects(:nature_whistle_alerts)
    :ets.delete_all_objects(:nature_whistle_notifiers)

    alerts = Application.get_env(:nature_whistle, :alerts, :default)
    notifiers = Application.get_env(:nature_whistle, :notifiers, :default)

    alerts_list = if alerts == :default, do: default_alerts(), else: alerts
    notifiers_list = if notifiers == :default, do: default_notifiers(), else: notifiers

    alerts_by_event =
      Enum.reduce(alerts_list, %{}, fn alert, acc ->
        event = Keyword.fetch!(alert, :event)

        alert_map = %{
          id: Keyword.fetch!(alert, :id),
          event: event,
          threshold: Keyword.fetch!(alert, :threshold),
          message: Keyword.fetch!(alert, :message),
          cooldown_ms: Keyword.get(alert, :cooldown_ms, 60_000),
          notifier: Keyword.get(alert, :notifier, :console)
        }

        Map.update(acc, event, [alert_map], &[alert_map | &1])
      end)

    alerts_by_event
    |> Enum.each(fn {event, alert_list} ->
      :ets.insert(:nature_whistle_alerts, {event, alert_list})
    end)

    notifiers_list
    |> Enum.each(fn {name, opts} ->
      :ets.insert(:nature_whistle_notifiers, {name, opts})
    end)
  end

  defp default_alerts do
    [
      [
        id: :high_memory,
        event: [:vm, :memory, :total],
        # 1 GB
        threshold: 1_073_741_824,
        message: "⚠️ High memory usage: %{value} MB",
        # 5 minutes
        cooldown_ms: 300_000,
        notifier: :console
      ],
      [
        id: :high_cpu,
        event: [:vm, :total_run_queue_lengths, :total],
        threshold: 5,
        message: "🚨 High CPU load: run queue length is %{value}",
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
