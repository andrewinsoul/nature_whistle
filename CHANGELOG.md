# Changelog

All notable changes to this project will be documented in this file.

## [0.4.0] - 2026-09-09

### Added

- **Alert Pack architecture** for defining extensible and composable groups of alerts.
- **BEAM/VM Alert Pack** with monitoring for:
  - Total memory
  - Process memory
  - ETS memory
  - Binary memory
  - Process count
  - Atom count
  - Port count
  - Run queue
- **Ecto Alert Pack** for monitoring slow queries, queue time, database execution time, decode time, and encode time.
- **Oban Alert Pack** for monitoring slow jobs, queue latency, job exceptions, and repeated job failures.
- **Runtime alert registration and unregistration** without requiring a server restart.
- **Automatic Telemetry handler synchronization** for dynamically registered and removed alerts.
- **Stateful Incident Tracking** to manage the complete lifecycle of an alert, from initial trigger through recovery.
- **Rich Alert Context** to include additional information such as threshold values, duration, environment, node, and custom metadata in notifications.
- **Alert Simulation** for validating alert rules, notification delivery, and formatter behavior without waiting for real production events.
- **BEAM metrics collector** for periodically collecting only the VM metrics required by configured BEAM alerts.
- **Runtime failure tracking** for aggregate failure detection and incident state management.

### Changed

- BEAM run-queue thresholds are normalized relative to the number of schedulers available on the system.
- Alert handlers are synchronized dynamically as alerts are added or removed at runtime.
- BEAM metric collection is driven by the metrics required by configured alerts.
- Alert configuration now supports disabling individual built-in alerts and overriding their default thresholds.

### Fixed

- Fixed BEAM collector startup ordering so configured metrics are applied only after the collector has been started.
- Fixed telemetry handler lifecycle management when runtime alerts are registered or removed.

---

## [0.3.0] - 2026-07-11

### Added

- Asynchronous notification delivery through `Task.Supervisor` so telemetry handlers stay lightweight.
- `NatureWhistle.BackgroundCleaner` to manage alert resolution timers and prune stale ETS buckets.
- `NatureWhistle.EventGuard` for rate limiting and sliding-window suppression of noisy alerts.
- `NatureWhistle.Notification` for message formatting, value rendering, and notifier profile dispatch.
- Custom per-alert `formatter` support with a safe fallback when formatting fails.
- Test support helpers for eventually-consistent assertions against async state changes.

### Changed

- Alert definitions are normalized into ETS and grouped by telemetry event at startup.
- Notification delivery now uses named notifier profiles from `:notifiers_config` instead of a single notifier entry per alert.
- Built-in HTTP notifiers accept map or keyword configuration and use `webhook_url` as the endpoint key.
- Console, Slack, Teams, and generic webhook delivery now share a common retry path with exponential backoff.
- Application startup now creates the task supervisor and background cleaner alongside the ETS tables.
- Default alert templates were refreshed and documented as built-in examples.

### Fixed

- Retry configuration is validated on startup so invalid backoff settings fail fast.
- Custom formatter failures no longer crash notification formatting.
- Stale rate-limit and sliding-window state is cleaned up automatically over time.

### Compatibility Notes

- Legacy alert configs using `:notifier` are still normalized, but the preferred shape is now `:notifiers` with named delivery profiles in `:notifiers_config`.
- `resolution_ms` remains the active alert lifecycle timer.
- `debounce_ms` is stored during normalization, but it is not yet part of the active runtime decision path.

---

## [0.2.0] - 2026-05-30

### Added

- Microsoft Teams notifier.
- Generic webhook notifier.
- Recovery notifications.

### Fixed

- Retry logic for HTTP delivery.

---

## [0.1.0] - 2026-04-20

### Added

- Initial public release.
- Slack notifier.
- Console notifier.
- Telemetry alerting.
