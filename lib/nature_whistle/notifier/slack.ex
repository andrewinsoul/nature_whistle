defmodule NatureWhistle.Notifier.Slack do
  @behaviour NatureWhistle.Notifier.Behaviour

  @impl true
  def deliver(message, _metadata, config) do
    webhook_url = Keyword.fetch!(config, :webhook_url)

    payload = %{text: message}

    case Req.post(webhook_url, json: payload) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, :sent}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Slack returned #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
