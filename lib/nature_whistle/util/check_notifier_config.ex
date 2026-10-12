defmodule NatureWhistle.Util.CheckNotifierConfig do
  @supported_notification_channels [:console, :webhook, :teams, :slack]

  def validate_notifier_config!(alert_notifiers, notifiers_config) do
    Enum.flat_map(alert_notifiers, fn notifier_name ->
      case Enum.find(notifiers_config, fn config ->
             is_map(config) and Map.get(config, :name) == notifier_name
           end) do
        nil ->
          raise ArgumentError, "Notifier config not found for #{inspect(notifier_name)}"

        notifier_config_map ->
          [notifier_config_map]
      end
    end)
  end

  defp default_notifiers,
    do: [
      %{
        name: :console,
        service: :console,
        config: nil
      }
    ]

  def validate_alert_notifiers!(alert) do
    validate_duplicate_alert_notifier!()
    alert_notifiers = Map.get(alert, :notifiers, [:console])

    notifiers_config =
      Application.get_env(
        :nature_whistle,
        :notifiers_config,
        default_notifiers()
      )

    allowed_configs =
      validate_notifier_config!(alert_notifiers, notifiers_config)

    Enum.each(allowed_configs, fn notifier_config ->
      unless notifier_config.service in @supported_notification_channels do
        raise ArgumentError,
              "Notifier profile #{inspect(Map.get(notifier_config, :name))} " <>
                "uses an unsupported service: #{inspect(notifier_config.service)}"
      end
    end)

    :ok
  end

  def validate_duplicate_alert_notifier!() do
    notifier_configs =
      Application.get_env(:nature_whistle, :notifiers_config, default_notifiers())

    notifer_service_names = Enum.map(notifier_configs, &Map.get(&1, :name))

    case notifer_service_names -- Enum.uniq(notifer_service_names) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "duplicate NatureWhistle notifier config names: #{inspect(Enum.uniq(duplicates))}, names of notifer configs has to be unique"
    end
  end
end
