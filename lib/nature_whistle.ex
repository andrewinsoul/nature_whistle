defmodule NatureWhistle do
  @moduledoc """
  `nature_whistle` is a telemetry‑driven alerting library for Elixir applications.

  It listens to `:telemetry` events, checks values against configured thresholds,
  and sends alerts to Slack, Microsoft Teams, generic webhooks, or the console.
  When a metric returns to normal, it sends a **calm** notification.

  ## Features

  - **Telemetry‑driven** – works with any `:telemetry` event (VM, Phoenix, Ecto, Oban, custom).
  - **Alert + Calm** – get notified both when a problem starts **and** when it resolves.
  - **Configurable thresholds, cooldown, resolution periods**.
  - **Multiple notifiers** – Slack, Teams, custom webhook, console.
  - **Automatic retries** for HTTP notifiers (exponential backoff).
  - **Low footprint** – uses only ETS tables and telemetry handlers, no extra processes.

  ## Usage

  `nature_whistle` is configured via your application’s `config/config.exs`.
  Add `NatureWhistle.Application` to your supervision tree.

  See the [README](https://github.com/andrewinsoul/nature_whistle) for detailed configuration examples.

  ## Example configuration

      # config/config.exs
      config :nature_whistle,
        alerts: [
          %{
            id: :high_memory,
            event: [:vm, :memory, :total],
            measurement_key: :total,
            threshold: 1_073_741_824,
            alert_message: "🚨 High memory: %{value} MB",
            calm_message: "✅ Memory back to normal: %{value} MB",
            notifier: :slack
          }
        ],
        notifiers: [
          slack: [webhook_url: "https://hooks.slack.com/..."]
        ]

  ## Supervision

  Add `NatureWhistle.Application` as a child of your main supervisor.

      children = [
        MyApp.Repo,
        MyAppWeb.Endpoint,
        NatureWhistle.Application
      ]

  ## Custom notifiers

  You can implement your own notifier by implementing the `NatureWhistle.Notifier.Behaviour` callback.
  """

  def default_alerts do
    [
      [
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
      ],
      [
        id: :high_cpu,
        event: [:vm, :total_run_queue_lengths, :total],
        threshold: 4,
        alert_message: "🚨 High CPU load: run queue length is %{value}",
        calm_message: "✅ CPU Queue length back to normal: %{value}",
        debounce_ms: 60_000,
        rate_limit: [window_ms: 60_000, max_events: 10],
        sliding_window: [window_ms: 30_000, max_events: 3],
        notifier: :console
      ]
    ]
  end

  @doc """
  Retrieves a full alert configuration map from the application environment by its ID.
  """
  def get_alert_config(alert_id) do
    alerts = Application.get_env(:nature_whistle, :alerts, default_alerts())

    alerts =
      Enum.map(alerts, fn alert ->
        cond do
          is_list(alert) -> Map.new(alert)
          is_map(alert) -> alert
          true -> %{}
        end
      end)

    Enum.find(alerts, fn alert -> alert.id == alert_id end)
  end
end
