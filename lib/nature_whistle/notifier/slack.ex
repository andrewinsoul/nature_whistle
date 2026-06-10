defmodule NatureWhistle.Notifier.Slack do
  @moduledoc """
  Sends alerts to a Slack channel via incoming webhook.

  ## Configuration

  In your `config/config.exs`:

      config :nature_whistle, notifiers: [
        slack: [webhook_url: "https://hooks.slack.com/services/..."]
      ]

  The only required option is `:webhook_url`.

  This notifier automatically retries failed requests (3 attempts by default) with exponential backoff.
  Retry settings can be adjusted under the `:retry` key in the `:nature_whistle` configuration.
  """
  alias NatureWhistle.Notifier.Retry
  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  def deliver(message, _metadata, config) do
    webhook_url = Keyword.fetch!(config, :webhook_url)
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
