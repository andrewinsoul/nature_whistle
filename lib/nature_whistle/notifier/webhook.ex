defmodule NatureWhistle.Notifier.Webhook do
  @moduledoc """
  Generic HTTP webhook notifier. Sends alerts to any endpoint.

  ## Configuration

  In your `config/config.exs`:

      config :nature_whistle, notifiers: [
        webhook: [
          url: "https://your.service/hook",
          method: :post,                # default :post
          headers: [{"x-api-key", "abc"}],
          body_template: :simple        # or :full, or a custom function
        ]
      ]

  ### Options

  * `:url` – required, the HTTP endpoint.
  * `:method` – optional, default `:post`. Can be `:put`, `:delete`, etc.
  * `:headers` – optional, list of `{header, value}` tuples.
  * `:body_template` – optional, controls the JSON payload:
    - `:simple` – sends `%{text: message}` (default).
    - `:full` – sends `%{text: message, metadata: metadata, timestamp: ...}`.
    - a function of arity 2 – receives `(message, metadata)` and returns a map.

  This notifier automatically retries failed requests (3 attempts by default) with exponential backoff.
  Retry settings can be adjusted under the `:retry` key in the `:nature_whistle` configuration.
  """

  @behaviour NatureWhistle.Notifier.Behaviour

  alias NatureWhistle.Notifier.Retry

  @impl true
  def deliver(message, metadata, config) do
    url = Keyword.fetch!(config, :url)
    method = Keyword.get(config, :method, :post)
    headers = Keyword.get(config, :headers, [])
    body_template = Keyword.get(config, :body_template, :simple)

    body = build_body(body_template, message, metadata)

    Retry.with_retry(fn ->
      case Req.request(method: method, url: url, headers: headers, json: body) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, :sent}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Webhook returned #{status}: #{body}"}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp build_body(:simple, message, _metadata) do
    %{text: message}
  end

  defp build_body(:full, message, metadata) do
    %{
      text: message,
      metadata: metadata,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_body(custom_fun, message, metadata) when is_function(custom_fun, 2) do
    custom_fun.(message, metadata)
  end

  defp build_body(_, message, _metadata) do
    %{text: message}
  end
end
