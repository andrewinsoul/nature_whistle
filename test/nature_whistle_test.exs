defmodule NatureWhistleTest do
  use ExUnit.Case, async: false

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)

    on_exit(fn ->
      if original_alerts do
        Application.put_env(:nature_whistle, :alerts, original_alerts)
      else
        Application.delete_env(:nature_whistle, :alerts)
      end
    end)

    :ok
  end

  test "default_alerts/0 returns the built-in alert templates" do
    alerts = NatureWhistle.default_alerts()

    assert length(alerts) == 2
    assert Enum.any?(alerts, &(&1[:id] == :high_memory))
    assert Enum.any?(alerts, &(&1[:id] == :high_cpu))
  end

  test "get_alert_config/1 resolves keyword and map alert definitions" do
    Application.put_env(:nature_whistle, :alerts, [
      [id: :keyword_alert, event: [:test, :keyword], threshold: 1],
      %{id: :map_alert, event: [:test, :map], threshold: 2}
    ])

    assert %{id: :keyword_alert, event: [:test, :keyword], threshold: 1} =
             NatureWhistle.get_alert_config(:keyword_alert)

    assert %{id: :map_alert, event: [:test, :map], threshold: 2} =
             NatureWhistle.get_alert_config(:map_alert)
  end

  test "get_alert_config/1 falls back to the built-in defaults when env is unset" do
    Application.delete_env(:nature_whistle, :alerts)

    assert %{id: :high_memory} = NatureWhistle.get_alert_config(:high_memory)
  end

  test "get_alert_config/1 returns nil for an unknown alert id" do
    Application.put_env(:nature_whistle, :alerts, [%{id: :known, event: [:x], threshold: 1}])

    assert is_nil(NatureWhistle.get_alert_config(:missing))
  end
end
