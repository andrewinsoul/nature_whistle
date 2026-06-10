defmodule NatureWhistle.Notifier.Behaviour do
  @moduledoc """
  Behaviour for implementing custom notifiers.

  A notifier is responsible for delivering an alert message to an external service
  (e.g., Slack, Teams, a custom webhook, or the console).

  > #### Current limitation {: .warning}
  > This behaviour is defined, but `nature_whistle` does **not** yet support using custom module notifiers directly.
  > Only the built‑in notifiers (`:slack`, `:teams`, `:webhook`, `:console`) are supported via atom keys.
  > Support for module names is planned for a future release.

  ## Built‑in notifiers

  - `NatureWhistle.Notifier.Slack`
  - `NatureWhistle.Notifier.Teams`
  - `NatureWhistle.Notifier.Webhook`
  - `NatureWhistle.Notifier.Console`
  """

  @doc """
  Delivers an alert message to the external service.

  Called by `nature_whistle` when an alert or calm message needs to be sent.

  ## Parameters

  - `message` – The fully formatted message string (placeholders already replaced).
  - `metadata` – A map of additional telemetry metadata (may be empty).
  - `config` – A keyword list of configuration options for this notifier, as defined in the host’s
    `config.exs` under `:notifiers` for the corresponding atom name. For custom module notifiers,
    `config` will be an empty list unless extended in the future.

  ## Return value

  Must return one of:

  - `{:ok, term()}` – on success (the term can be anything, e.g., `:sent`).
  - `{:error, reason}` – on failure (reason should be a string or an error term).
  """
  @callback deliver(message :: String.t(), metadata :: map(), config :: keyword()) ::
              {:ok, term()} | {:error, term()}
end
