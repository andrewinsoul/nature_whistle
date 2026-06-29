# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
