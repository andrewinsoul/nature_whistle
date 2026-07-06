# 1. Update configuration with a 60-second resolution
test_alert = %{
  id: :iex_debounce_test,
  event: [:iex, :test],
  measurement_key: :latency,
  threshold: 100,
  alert_message: "🚨 ALERT: Database latency spike!",
  calm_message: "✨ CALM: Database latency has recovered.",
  sliding_window: [window_ms: 5000, max_events: 10],
  # 60 seconds
  resolution_ms: 60_000,
  notifier: :console
}

:ets.insert(
  :nature_whistle_alerts,
  {[:iex, :test],
   [
     test_alert
   ]}
)

Application.put_env(:nature_whistle, :alerts, [test_alert])

# 2. Hard flush the state table just to be absolutely sure we're starting clean
:ets.delete_all_objects(:nature_whistle_alert_state)

# 3.
:telemetry.attach(
  "iex_debounce_test",
  [:iex, :test],
  &NatureWhistle.EventHandler.handle_event/4,
  %{}
)

# 4.
:telemetry.execute([:iex, :test], %{latency: 150}, %{})

#  If you wanna detach
:telemetry.detach("iex_debounce_test")

# List all items in an ets table
:ets.tab2list(:table_name)
