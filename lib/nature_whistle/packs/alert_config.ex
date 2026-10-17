defmodule NatureWhistle.Packs.AlertConfig do
  @moduledoc """
  Shared helpers for applying pack-level options to generated alert definitions.
  """

  @doc """
  Applies a pack's `:notifiers` option to every generated alert.

  When `:notifiers` is omitted, the alert definitions are returned unchanged so
  existing default notifier behaviour is preserved.
  """
  @spec apply_notifiers([map()], keyword()) :: [map()]
  def apply_notifiers(alerts, opts) when is_list(alerts) and is_list(opts) do
    case Keyword.fetch(opts, :notifiers) do
      {:ok, notifiers} when is_list(notifiers) ->
        Enum.map(alerts, &Map.put(&1, :notifiers, notifiers))

      {:ok, invalid} ->
        raise ArgumentError,
              "Invalid :notifiers option, expected a list of notifier names, got: #{inspect(invalid)}"

      :error ->
        alerts
    end
  end
end
