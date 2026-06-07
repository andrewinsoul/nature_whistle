defmodule NatureWhistle.Notifier.Behaviour do
  @moduledoc """
  Behaviour for notifiers that deliver alerts to external services.
  """

  @doc """
  Delivers an alert message to the configured service.

  Returns `{:ok, response}` on success, `{:error, reason}` on failure.
  """
  @callback deliver(message :: String.t(), metadata :: map(), config :: keyword()) ::
              {:ok, term()} | {:error, term()}
end
