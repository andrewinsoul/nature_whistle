defmodule NatureWhistle.Packs.AlertConfig do
  @moduledoc """
  Shared helpers for applying pack-level options to generated alert definitions.
  """

  @doc """
  Applies a pack's `:notifiers` option to generated alerts that do not already
  define an alert-level `:notifiers` or legacy `:notifier` option.

  When `:notifiers` is omitted, the alert definitions are returned unchanged so
  they can inherit the global default during alert normalization.
  """
  @spec apply_notifiers([map()], keyword()) :: [map()]
  def apply_notifiers(alerts, opts) when is_list(alerts) and is_list(opts) do
    case Keyword.fetch(opts, :notifiers) do
      {:ok, notifiers} when is_list(notifiers) ->
        Enum.map(alerts, fn alert ->
          if Map.has_key?(alert, :notifiers) or Map.has_key?(alert, :notifier) do
            alert
          else
            Map.put(alert, :notifiers, notifiers)
          end
        end)

      {:ok, invalid} ->
        raise ArgumentError,
              "Invalid :notifiers option, expected a list of notifier names, got: #{inspect(invalid)}"

      :error ->
        alerts
    end
  end
end
