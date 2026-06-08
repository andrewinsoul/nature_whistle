defmodule NatureWhistle.Notifier.Webhook do
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
