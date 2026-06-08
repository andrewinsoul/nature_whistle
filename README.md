# NatureWhistle
![NatureWhistle Banner](assets/img/nature_whistle.jpeg)
# NatureWhistle


**NatureWhistle** is an Elixir library that listens to `:telemetry` events and sends alerts to collaboration tools (Slack, Microsoft Teams, generic webhooks, or the console) when metric thresholds are crossed. It also sends resolution (“calm”) notifications when a metric returns to normal.

> The name combines “nature” – the author’s nickname – with “whistle”, because it sounds an alarm when something goes wrong and blows a calming note when the system recovers.

## Features

- 📊 **Telemetry‑driven** – works with any `:telemetry` event (VM metrics, Phoenix, Ecto, Oban, custom application metrics).
- 🚨 **Spike + resolution alerts** – be notified both when a problem starts **and** when it resolves.
- ⚙️ **Configurable thresholds** – set per‑alert thresholds, cooldowns, and resolution stabilisation periods.
- 🔌 **Multiple notifiers** – Slack, Microsoft Teams, generic webhook, console (for development).
- 🔁 **Automatic retries** – exponential backoff with configurable attempts and delay caps for HTTP notifiers.
- 🧩 **Extensible** – add your own notifiers or customise request bodies.
- 💼 **Ready for production** – fault‑tolerant via host supervision, ETS storage, and safe telemetry handling.

## Installation

Add `nature_whistle` to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:nature_whistle, "~> 0.1.0"}
  ]
end
```

Then run mix deps.get.

### Configuration

Configuration is placed in your host application’s config/config.exs. You can define alerts, notifiers, and retry behaviour.

### Basic example

```elixir
import Config

config :nature_whistle,
  alerts: [
    %{
      id: :high_memory,
      event: [:vm, :memory, :total],
      measurement_key: :total,
      threshold: 1_073_741_824,        # 1 GB
      alert_message: "🚨 High memory: %{value} MB",
      calm_message: "✅ Memory back to normal: %{value} MB",
      cooldown_ms: 300_000,            # 5 minutes
      resolution_ms: 60_000,           # 1 minute
      notifier: :slack
    }
  ],
  notifiers: [
    slack: [webhook_url: "https://hooks.slack.com/services/..."],
    console: []   # optional, always available as fallback
  ],
  retry: [
    max_attempts: 3,
    base_delay_ms: 1000,
    max_delay_ms: 30_000
  ]
```

### Alert fields

| Field             | Required                | Description                                                                                  |
| ----------------- | ----------------------- | -------------------------------------------------------------------------------------------- |
| `id`              | ✅                      | Unique identifier for this alert (used for state & cooldown).                                |
| `event`           | ✅                      | Telemetry event name as a list of atoms, e.g. `[:vm, :memory, :total]`.                      |
| `measurement_key` | ❌ (default `:value`)   | Key inside the `measurements` map that holds the numeric value (e.g. `:duration`, `:total`). |
| `threshold`       | ✅                      | Numeric value that triggers the alert (when `value >= threshold`).                           |
| `alert_message`   | ❌                      | Message sent when threshold is crossed. Use `%{value}` as placeholder.                       |
| `calm_message`    | ❌                      | Message sent when metric stays below threshold for `resolution_ms`.                          |
| `cooldown_ms`     | ❌ (default 60 000)     | Minimum time between repeated alert messages while the metric remains high.                  |
| `resolution_ms`   | ❌ (default 60 000)     | Time the metric must stay below threshold before sending the calm message.                   |
| `notifier`        | ❌ (default `:console`) | One of `:slack`, `:teams`, `:webhook`, or `:console`.                                        |

### Notifier configuration

Notifiers are configured under the `:notifiers` key. Each notifier expects a keyword list of options:

- **Slack** / **Teams**  
  `slack: [webhook_url: "https://hooks.slack.com/..."]`  
  `teams: [webhook_url: "https://outlook.office.com/webhook/..."]`

- **Webhook (generic)**
  ```elixir
  webhook: [
    url: "https://my.service/hook",
    method: :post,                 # default :post
    headers: [{"x-api-key", "abc"}],
    body_template: :simple        # or :full, or a custom function
  ]
  ```

### Retry settings

Under the :retry key you can configure:

- max_attempts – how many times to retry (default 3)

- base_delay_ms – initial delay in milliseconds (default 1000)

- max_delay_ms – upper bound for the exponential backoff (default 30 000)

### Starting NatureWhistle

Add NatureWhistle.Application to your application’s supervision tree. This ensures the package is started, its ETS tables are created, and telemetry handlers are attached.

```elixir
 # lib/my_app/application.ex
def start(_type, _args) do
 children = [
   MyApp.Repo,
   MyAppWeb.Endpoint,
   NatureWhistle.Application      # <-- add this line
 ]
 Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Note:

`nature_whistle` works with **any Elixir (or Erlang) application** that emits `:telemetry` events – it does not require Phoenix. Simply add `NatureWhistle.Application` as a child of your application's supervision tree.

### Usage

Once configured and started, nature_whistle automatically listens to telemetry events. You do not need to call any additional functions – just emit events as usual.

### Emitting custom telemetry events

Your application can emit its own events, and nature_whistle will alert on them if you add a corresponding alert entry.

```elixir
 # Example: emit a slow query event
:telemetry.execute(
  [:my_app, :db, :query],
  %{duration: 650},                     # value under :duration
  %{query: "SELECT * FROM users"}
)
```

Then define an alert:

```elixir
%{
  id: :slow_query,
  event: [:my_app, :db, :query],
  measurement_key: :duration,
  threshold: 500,
  alert_message: "🐢 Slow query: %{value} ms",
  calm_message: "✅ Query speed recovered: %{value} ms"
}
```

### Default alerts

If you do not specify any :alerts, nature_whistle provides two built‑in alerts that use the console notifier:

- High memory (1 GB threshold)

- High CPU run queue length (threshold 5)

This ensures the package is never idle – you will always see warnings in the logs if there is any spike.

## How it works

- On startup, `NatureWhistle.Application` creates three ETS tables:
  - `:nature_whistle_alerts` – stores alerts indexed by telemetry event
  - `:nature_whistle_notifiers` – stores notifier configurations
  - `:nature_whistle_alert_state` – tracks current state (`:firing` or `:calm`) and timestamps
- Telemetry handlers are attached for every event that has at least one alert.
- When a telemetry event occurs, the handler extracts the numeric value using the configured `measurement_key`, compares it with the threshold, and updates the state machine.
- If the value rises above threshold, an **alert** message is sent (respecting cooldown). If the value later stays below threshold for `resolution_ms`, a **calm** message is sent.
- HTTP notifiers automatically retry failed requests using exponential backoff with configurable attempts and delay cap.

### Fault tolerance & supervision

- NatureWhistle.Application is meant to be added as a child of your main supervisor. If it crashes, the host supervisor restarts it, re‑creating all ETS tables and re‑attaching handlers.

- Telemetry handlers run inside the process that emitted the event. They are wrapped in try/rescue to prevent any exception from crashing the host process. Errors are logged, and alert evaluation continues for subsequent events.

## Customising messages

Both `alert_message` and `calm_message` support the `%{value}` placeholder, which is replaced with the current metric value (converted to a string). Memory values for `[:vm, :memory, :total]` are automatically formatted as megabytes for readability. For all other metrics, the raw value is inserted as a string.

> **Future enhancement** – A future version of `nature_whistle` will allow you to provide a custom formatting function per alert (e.g., converting microseconds to milliseconds, adding units). Currently, formatting is limited to built‑in VM memory conversion.

## Contributing & Feedback

NatureWhistle is an open source project that thrives on community input. Whether you have a bug report, a feature request, a question, or want to contribute code, you are very welcome.

- **Issues & Discussions** – Please use the GitHub issue tracker to report bugs or suggest enhancements. For questions or general feedback, start a Discussion.
- **Pull Requests** – Contributions are encouraged. If you plan to add a non‑trivial feature, open an issue first to discuss the design.
- **Roadmap** – Future ideas include custom value formatters, more notifiers (Discord, Mattermost, Opsgenie), and configurable retry per notifier. Your feedback helps prioritise.

Let’s make `nature_whistle` the go‑to alerting toolkit for the Elixir ecosystem. 🌿🔊
