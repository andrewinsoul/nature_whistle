defmodule NatureWhistle.Notifier.Webhook do
  @moduledoc """
  Generic HTTP webhook notifier. Sends alerts to any endpoint.

  ## Configuration

  In your `config/config.exs`:

      config :nature_whistle, notifiers: [
        %{
          name: :webhook,
          config: %{
            webhook_url: "https://your.service/hook"
            method: :post, # default :post
            headers: [{"x-api-key", "abc"}, {"Origin", "origin"}],
            payload: %{text: "alert message"}
          }
        }
      ]

  ### Options

  * `:webhook_url` – required, the HTTP endpoint.
  * `:method` – optional, default `:post`. Can be `:put`, `:delete`, etc.
  * `:headers` – optional, list of `{header, value}` tuples.
  * `:payload` – optional, controls the JSON payload:, defaults to %{text: "alert or calm message"}

  This notifier automatically retries failed requests (3 attempts by default) with exponential backoff.
  Retry settings can be adjusted under the `:retry` key in the `:nature_whistle` configuration.
  """

  alias NatureWhistle.Notifier.Retry

  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  def deliver(message, _metadata, config) do
    config =
      cond do
        is_list(config) -> Map.new(config)
        is_map(config) -> config
        true -> nil
      end

    webhook_url = Map.fetch!(config, :webhook_url)
    custom_payload = Map.get(config, :payload, %{})
    payload = Map.put(custom_payload, :text, message)
    headers = Map.get(config, :headers, [])
    method = Map.get(config, :method, :post)

    Retry.with_retry(fn ->
      case Req.request(method: method, url: webhook_url, headers: headers, json: payload) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, :sent}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Webhook returned #{status}: #{body}"}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end
end
