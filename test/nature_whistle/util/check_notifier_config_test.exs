defmodule NatureWhistle.Util.CheckNotifierConfigTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Util.CheckNotifierConfig

  setup do
    original = Application.get_env(:nature_whistle, :notifiers_config)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:nature_whistle, :notifiers_config)
        config -> Application.put_env(:nature_whistle, :notifiers_config, config)
      end
    end)

    :ok
  end

  test "validates the default console notifier when no notifier config is set" do
    Application.delete_env(:nature_whistle, :notifiers_config)

    assert :ok = CheckNotifierConfig.validate_alert_notifiers!(%{})
  end

  test "accepts a configured supported notifier" do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :ops, service: :slack, config: %{webhook_url: "https://example.com"}}
    ])

    assert :ok = CheckNotifierConfig.validate_alert_notifiers!(%{notifiers: [:ops]})
  end

  test "rejects an unsupported notifier service" do
    secret = "webhook-secret-token-123"
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{
        name: :ops,
        service: :unknown,
        config: %{
          webhook_url: "https://example.com/#{secret}",
          headers: [{"authorization", secret}],
          payload: %{api_token: secret}
        }
      }
    ])

    error =
      assert_raise ArgumentError, ~r/unsupported service/, fn ->
        CheckNotifierConfig.validate_alert_notifiers!(%{notifiers: [:ops]})
      end

    refute Exception.message(error) =~ secret
    assert Exception.message(error) =~ ":ops"
  end

  test "rejects a notifier name that has no configured profile" do
    Application.put_env(:nature_whistle, :notifiers_config, [])

    assert_raise ArgumentError, ~r/Notifier config not found for :missing/, fn ->
      CheckNotifierConfig.validate_alert_notifiers!(%{notifiers: [:missing]})
    end
  end

  test "rejects duplicate notifier profile names" do
    Application.put_env(:nature_whistle, :notifiers_config, [
      %{name: :ops, service: :console, config: nil},
      %{name: :ops, service: :slack, config: %{}}
    ])

    assert_raise ArgumentError, ~r/duplicate NatureWhistle notifier config names/, fn ->
      CheckNotifierConfig.validate_alert_notifiers!(%{notifiers: [:ops]})
    end
  end

  test "ignores non-map entries when resolving notifier profiles" do
    configs = [
      :invalid_entry,
      %{name: :ops, service: :console, config: nil}
    ]

    assert [%{name: :ops}] = CheckNotifierConfig.validate_notifier_config!([:ops], configs)
  end
end
