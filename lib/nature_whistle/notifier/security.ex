defmodule NatureWhistle.Notifier.Security do
  @moduledoc false

  @sensitive_key_fragments ~w(
    password
    secret
    token
    authorization
    cookie
    api_key
    private_key
    credential
  )

  @doc false
  def validate_webhook_url(config) when is_map(config) do
    webhook_url = Map.fetch!(config, :webhook_url)
    uri = URI.parse(webhook_url)

    scheme = String.downcase(uri.scheme || "")
    valid_host? = is_binary(uri.host) and uri.host != ""

    cond do
      scheme == "https" and valid_host? ->
        :ok

      scheme == "http" and valid_host? and Map.get(config, :allow_insecure_http, false) ->
        :ok

      scheme == "http" and valid_host? ->
        {:error, :insecure_webhook_url}

      true ->
        {:error, :invalid_webhook_url}
    end
  end

  @redacted "[REDACTED]"

  @doc false
  def redact_metadata(value) do
    configured_keys = Application.get_env(:nature_whistle, :sensitive_metadata_keys, [])
    redact_metadata(value, configured_keys)
  end

  @doc false
  def redact_metadata(value, configured_keys) do
    sensitive_keys =
      configured_keys
      |> List.wrap()
      |> Enum.map(&normalize_key/1)
      |> MapSet.new()

    redact_value(value, sensitive_keys)
  end

  @doc false
  def redact_measurement(event, value) do
    sensitive_events = Application.get_env(:nature_whistle, :sensitive_metrics, [])

    if Enum.any?(List.wrap(sensitive_events), &(&1 == event)) do
      @redacted
    else
      value
    end
  end

  defp redact_value(%_{} = value, sensitive_keys) do
    value
    |> Map.from_struct()
    |> redact_value(sensitive_keys)
    |> then(&struct(value.__struct__, &1))
  end

  defp redact_value(value, sensitive_keys) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      redacted_value =
        if sensitive_key?(key, sensitive_keys) do
          @redacted
        else
          redact_value(nested_value, sensitive_keys)
        end

      {key, redacted_value}
    end)
  end

  defp redact_value(value, sensitive_keys) when is_list(value),
    do: Enum.map(value, &redact_value(&1, sensitive_keys))

  defp redact_value({key, nested_value}, sensitive_keys)
       when is_atom(key) or is_binary(key) do
    redacted_value =
      if sensitive_key?(key, sensitive_keys) do
        @redacted
      else
        redact_value(nested_value, sensitive_keys)
      end

    {key, redacted_value}
  end

  defp redact_value(value, sensitive_keys) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> redact_value(sensitive_keys)
    |> List.to_tuple()
  end

  defp redact_value(value, _sensitive_keys), do: value

  defp sensitive_key?(key, sensitive_keys) do
    key_name = normalize_key(key)

    Enum.any?(@sensitive_key_fragments, fn fragment ->
      String.contains?(key_name, normalize_key(fragment))
    end) or MapSet.member?(sensitive_keys, key_name)
  end

  defp normalize_key(key) do
    key
    |> inspect()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  @doc false
  def validate_sensitive_metrics! do
    case Application.get_env(:nature_whistle, :sensitive_metrics, []) do
      events when is_list(events) ->
        unless Enum.all?(events, &valid_sensitive_metric?/1) do
          raise ArgumentError,
                """
                Invalid configuration for :sensitive_metrics.
                Expected a list of non-empty Telemetry event names (lists of atoms), got: #{inspect(events)}
                """
        end

        :ok

      invalid ->
        raise ArgumentError,
              """
              Invalid configuration for :sensitive_metrics.
              Expected a list of non-empty Telemetry event names (lists of atoms), got: #{inspect(invalid)}
              """
    end
  end

  defp valid_sensitive_metric?(event) when is_list(event) and event != [] do
    Enum.all?(event, &is_atom/1)
  end

  defp valid_sensitive_metric?(_event), do: false

  def validate_sensitive_metadata_keys! do
    case Application.get_env(:nature_whistle, :sensitive_metadata_keys, []) do
      keys when is_list(keys) ->
        unless Enum.all?(keys, &valid_sensitive_metadata_key?/1) do
          raise ArgumentError,
                """
                Invalid configuration for :sensitive_metadata_keys.
                Expected a list of non-empty atoms or non-empty strings, \
                got: #{inspect(keys)}
                """
        end

        :ok

      invalid ->
        raise ArgumentError,
              """
              Invalid configuration for :sensitive_metadata_keys.
              Expected a list of non-empty atoms or non-empty strings, \
              got: #{inspect(invalid)}
              """
    end
  end

  defp valid_sensitive_metadata_key?(key) when is_atom(key) do
    String.trim(Atom.to_string(key)) != ""
  end

  defp valid_sensitive_metadata_key?(key) when is_binary(key) do
    String.trim(key) != ""
  end

  defp valid_sensitive_metadata_key?(_key), do: false
end
