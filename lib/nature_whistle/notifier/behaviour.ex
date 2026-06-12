defmodule NatureWhistle.Notifier.Behaviour do
  @moduledoc """
  Behaviour for implementing custom notifiers.

  A notifier is responsible for delivering an alert message to an external service.

  ## Implementing a custom notifier

  To create your own notifier, define a module that adopts this behaviour and implements `deliver/3`.

  ### Example

      defmodule MyApp.Notifiers.Discord do
        @behaviour NatureWhistle.Notifier.Behaviour

        @impl true
        def deliver(message, _metadata, config) do
          url = Keyword.fetch!(config, :webhook_url)
          # send HTTP request...
          {:ok, :sent}
        end
      end

  Then use the module name as the `:notifier` in your alert configuration:

      %{
        id: :some_alert,
        notifier: MyApp.Notifiers.Discord,
        notifier_config: [webhook_url: "https://discord.com/..."]
      }

  > #### Supported {: .info}
  > Starting from v0.2.0, any module that implements this behaviour can be used as a notifier.
  > The optional `:notifier_config` field is passed as the third argument to `deliver/3`.
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
