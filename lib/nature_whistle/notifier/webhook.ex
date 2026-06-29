defmodule NatureWhistle.Notifier.Webhook do
  @moduledoc """
  Generic HTTP webhook delivery backend.

  This notifier sends the formatted message to any HTTP endpoint using `Req`.
  It is the most flexible of the built-in delivery modules because it allows
  the HTTP method, headers, and JSON payload shape to be customized.

  Required config:

  - `:webhook_url` - the destination URL

  Optional config:

  - `:method` - HTTP verb, defaults to `:post`
  - `:headers` - a list of request headers
  - `:payload` - a base JSON map merged with `%{text: message}`

  Retry behavior is shared with Slack and Teams through
  `NatureWhistle.Notifier.Retry`.
  """

  alias NatureWhistle.Notifier.Retry

  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  @doc """
  Delivers a message to an arbitrary webhook endpoint.

  The notifier accepts either a keyword list or a map. The final JSON payload is
  built by merging the configured `:payload` map with `%{text: message}`.
  """
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
