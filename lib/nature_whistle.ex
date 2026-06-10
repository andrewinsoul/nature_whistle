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
end
