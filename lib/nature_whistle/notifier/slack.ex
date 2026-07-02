defmodule NatureWhistle.Notifier.Slack do
  @moduledoc """
  Slack webhook delivery backend.

  This notifier sends a single JSON payload of the form `%{text: message}` to a
  Slack incoming webhook URL. It accepts its configuration as either a map or a
  keyword list, which makes it easy to place directly in application config.

  Required config:

  - `:webhook_url` - the Slack incoming webhook endpoint

  All HTTP retry behavior is delegated to `NatureWhistle.Notifier.Retry`.
  """
  alias NatureWhistle.Notifier.Retry
  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  @doc """
  Delivers a Slack message using an incoming webhook.

  The payload is always `%{text: message}`. Any non-success HTTP status or
  transport error is retried according to the configured retry policy.
  """
  def deliver(message, _metadata, config) do
    config =
      cond do
        is_list(config) -> Map.new(config)
        is_map(config) -> config
        true -> %{}
      end

    webhook_url = Map.fetch!(config, :webhook_url)
    payload = %{text: message}

    Retry.with_retry(fn ->
      case Req.post(webhook_url, json: payload) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, :sent}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{body}"}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end
end
