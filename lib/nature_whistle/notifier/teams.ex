defmodule NatureWhistle.Notifier.Teams do
  @moduledoc """
  Microsoft Teams webhook delivery backend.

  Teams delivery mirrors the Slack notifier closely: the message is wrapped in a
  `%{text: message}` payload and POSTed to the configured webhook URL.

  Required config:

  - `:webhook_url` - the Teams incoming webhook endpoint; HTTPS is required by
    default

  Optional config:

  - `:allow_insecure_http` - explicitly permits an `http://` URL for local or
    trusted private testing

  Retry handling is shared with the other HTTP notifiers through
  `NatureWhistle.Notifier.Retry`.
  """
  alias NatureWhistle.Notifier.{Retry, Security}
  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  @doc """
  Delivers a Teams message using an incoming webhook.

  The notifier expects a successful `2xx` response. Any other response or
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

    with :ok <- Security.validate_webhook_url(config) do
      Retry.with_retry(fn ->
        case Req.post(webhook_url, json: payload) do
          {:ok, %Req.Response{status: 200}} ->
            {:ok, :sent}

          {:ok, %Req.Response{status: _status}} ->
            {:error, :teams_request_failed}

          {:error, _reason} ->
            {:error, :teams_request_failed}
        end
      end)
    end
  end
end
