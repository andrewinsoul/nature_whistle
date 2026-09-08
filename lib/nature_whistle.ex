defmodule NatureWhistle do
  @moduledoc """
  `NatureWhistle` is the public entry point for the library.

  It holds the default alert templates shipped with the project and provides
  helpers for looking up alert definitions from application configuration.

  The runtime itself is started through `NatureWhistle.Application`, but this
  module is still useful because it documents the shape of the alert structures
  that flow through the rest of the system:

  - alert definitions are configured as maps or keyword lists
  - alerts are grouped by telemetry event
  - values are compared against a numeric `threshold`
  - optional `formatter`, `rate_limit`, `sliding_window`, and `resolution_ms`
    settings change how an alert behaves at runtime
  - delivery targets are selected by profile names listed in `notifiers`

  The module also returns the built-in sample alerts used when no custom alerts
  are configured. These are convenient examples for documentation and testing,
  and the application loader understands both the older `:notifier` key and the
  newer `:notifiers` profile list when normalizing them.
  """

  @doc """
  Looks up a single alert definition by `alert_id`.

  The lookup first checks the alerts loaded into the running ETS registry,
  which includes runtime-registered alerts. If the registry is not available,
  or the alert is not present there, it falls back to application configuration
  and the built-in defaults.

  Both keyword lists and maps are accepted in the configuration source. The
  helper normalizes each alert into a map so callers can rely on dot access
  in the rest of the codebase.

  ## Return value

  - returns the matching alert map when found
  - returns `nil` when no alert with the requested ID exists
  """
  def get_alert_config(alert_id) do
    case :ets.whereis(:nature_whistle_alerts) do
      :undefined ->
        config_alert(alert_id)

      _ ->
        case :ets.foldl(
               fn {_event, alerts}, acc ->
                 case acc do
                   nil -> Enum.find(alerts, &(&1.id == alert_id))
                   alert -> alert
                 end
               end,
               nil,
               :nature_whistle_alerts
             ) do
          nil -> config_alert(alert_id)
          alert -> alert
        end
    end
  end

  defp config_alert(alert_id) do
    alerts = Application.get_env(:nature_whistle, :alerts, NatureWhistle.Packs.Beam.alerts([]))

    alerts
    |> Enum.map(fn alert ->
      cond do
        is_list(alert) -> Map.new(alert)
        is_map(alert) -> alert
        true -> %{}
      end
    end)
    |> Enum.find(fn alert -> Map.get(alert, :id) == alert_id end)
  end

  @doc """
  Registers an alert in the currently running NatureWhistle instance.

  Runtime registrations are ephemeral and are not persisted across a BEAM
  restart. The alert uses the same notification pipeline as configured alerts.
  """
  def register_alert(alert) do
    NatureWhistle.Application.register_alert(alert)
  end

  @doc """
  Removes a runtime alert from the currently running NatureWhistle instance.
  """
  def unregister_alert(alert_id) do
    if :ets.whereis(:nature_whistle_alerts) == :undefined do
      {:error, :not_started}
    else
      NatureWhistle.Application.unregister_alert(alert_id)
    end
  end
end
