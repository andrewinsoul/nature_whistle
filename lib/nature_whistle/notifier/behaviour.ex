defmodule NatureWhistle.Notifier.Behaviour do
  @moduledoc """
  Shared delivery contract for notifier modules.

  The built-in notifier modules (`Console`, `Slack`, `Teams`, and `Webhook`)
  all implement this behaviour. The callback signature is intentionally small so
  it can describe both simple log-based delivery and HTTP-based delivery.

  The current dispatcher routes built-in services by name (`:console`,
  `:slack`, `:teams`, and `:webhook`). This behaviour documents the shape of
  the delivery function itself, which is useful when reading the notifier
  implementations or when building a compatible integration in your own code.
  """

  @doc """
  Delivers an already formatted alert message.

  Implementations receive:

  - `message` - the final human-readable message with placeholders replaced
  - `metadata` - the telemetry metadata associated with the event
  - `config` - notifier-specific configuration, usually a map or keyword list

  Implementations should return:

  - `{:ok, term()}` when the delivery succeeded
  - `{:error, reason}` when the delivery failed
  """
  @callback deliver(message :: String.t(), metadata :: map(), config :: keyword()) ::
              {:ok, term()} | {:error, term()}
end
