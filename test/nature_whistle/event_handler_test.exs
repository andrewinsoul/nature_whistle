defmodule CustomTestNotifier do
  @behaviour NatureWhistle.Notifier.Behaviour

  use Agent

  def start_link(_) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def deliver(message, metadata, config) do
    Agent.update(__MODULE__, &[%{message: message, metadata: metadata, config: config} | &1])
    {:ok, :delivered}
  end

  def get_deliveries do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end

defmodule NatureWhistle.EventHandlerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    :ets.delete_all_objects(:nature_whistle_alert_state)
    :ets.delete_all_objects(:nature_whistle_cooldown)

    # Default alerts for most tests (console notifier)
    Application.put_env(:nature_whistle, :alerts, [
      %{
        id: :test_alert,
        event: [:test, :metric],
        measurement_key: :value,
        threshold: 10,
        alert_message: "ALERT: %{value}",
        calm_message: "CALM: %{value}",
        cooldown_ms: 100,
        resolution_ms: 50,
        notifier: :console
      },
      %{
        id: :memory_test,
        event: [:vm, :memory, :total],
        measurement_key: :total,
        threshold: 1_000_000,
        alert_message: "MEMORY: %{value} MB",
        calm_message: "MEMORY CALM",
        notifier: :console
      }
    ])

    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

    :telemetry.attach(
      "test-metric-handler",
      [:test, :metric],
      &NatureWhistle.EventHandler.handle_event/4,
      nil
    )

    :telemetry.attach(
      "test-memory-handler",
      [:vm, :memory, :total],
      &NatureWhistle.EventHandler.handle_event/4,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-metric-handler")
      :telemetry.detach("test-memory-handler")
    end)

    :ok
  end

  test "sends alert when value exceeds threshold" do
    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 15}, %{})
        Process.sleep(10)
      end)

    assert log =~ "ALERT: 15"
  end

  test "formats memory value in MB" do
    log =
      capture_log(fn ->
        :telemetry.execute([:vm, :memory, :total], %{total: 2_000_000_000}, %{})
        Process.sleep(10)
      end)

    assert log =~ "MB"
  end

  test "does not send alert when value below threshold" do
    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 5}, %{})
        Process.sleep(10)
      end)

    refute log =~ "ALERT"
  end

  test "cooldown prevents repeated alerts" do
    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 15}, %{})
        :telemetry.execute([:test, :metric], %{value: 20}, %{})
        Process.sleep(10)
      end)

    assert count_occurrences(log, "ALERT") == 1
  end

  test "sends calm message after resolution period" do
    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 15}, %{})
        Process.sleep(10)
        :telemetry.execute([:test, :metric], %{value: 5}, %{})
        Process.sleep(60)
        :telemetry.execute([:test, :metric], %{value: 5}, %{})
        Process.sleep(10)
      end)

    assert log =~ "ALERT: 15"
    assert log =~ "CALM: 5"
  end

  test "warns when notifier config is missing" do
    Application.put_env(:nature_whistle, :alerts, [
      %{
        id: :missing_config,
        event: [:test, :metric],
        threshold: 0,
        alert_message: "test",
        notifier: :missing
      }
    ])

    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

    :telemetry.attach(
      "missing-config-test",
      [:test, :metric],
      &NatureWhistle.EventHandler.handle_event/4,
      nil
    )

    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 100}, %{})
        Process.sleep(10)
      end)

    assert log =~ "Custom notifier module :missing is not loaded or does not implement deliver/3"

    :telemetry.detach("missing-config-test")

    Application.put_env(:nature_whistle, :alerts, [])
    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())
  end

  test "warns when notifier is unsupported" do
    Application.put_env(:nature_whistle, :alerts, [
      %{
        id: :unsupported,
        event: [:test, :metric],
        threshold: 0,
        alert_message: "test",
        notifier: "unknown"
      }
    ])

    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

    :telemetry.attach(
      "unsupported-test",
      [:test, :metric],
      &NatureWhistle.EventHandler.handle_event/4,
      nil
    )

    log =
      capture_log(fn ->
        :telemetry.execute([:test, :metric], %{value: 100}, %{})
        Process.sleep(10)
      end)

    assert log =~ ~r/Unsupported notifier: [:\"]?unknown[:\"]?/

    :telemetry.detach("unsupported-test")
    Application.put_env(:nature_whistle, :alerts, [])
    NatureWhistle.Application.load_config_into_ets(System.schedulers_online())
  end

  describe "custom notifier module" do
    setup do
      {:ok, _} = CustomTestNotifier.start_link(nil)
      CustomTestNotifier.clear()

      Application.put_env(:nature_whistle, :alerts, [
        %{
          id: :custom_test,
          event: [:test, :custom],
          measurement_key: :value,
          threshold: 10,
          alert_message: "CUSTOM ALERT: %{value}",
          calm_message: "CUSTOM CALM: %{value}",
          cooldown_ms: 100,
          resolution_ms: 50,
          notifier: CustomTestNotifier,
          notifier_config: [test_key: "test_value"]
        }
      ])

      NatureWhistle.Application.load_config_into_ets(System.schedulers_online())

      :telemetry.attach(
        "custom-notifier-test",
        [:test, :custom],
        &NatureWhistle.EventHandler.handle_event/4,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("custom-notifier-test")

        Application.put_env(:nature_whistle, :alerts, [])
        NatureWhistle.Application.load_config_into_ets(System.schedulers_online())
      end)

      :ok
    end

    test "sends alert to custom module notifier" do
      :telemetry.execute([:test, :custom], %{value: 15}, %{})
      Process.sleep(50)

      deliveries = CustomTestNotifier.get_deliveries()
      assert length(deliveries) == 1
      [delivery] = deliveries
      assert delivery.message =~ "CUSTOM ALERT: 15"
      assert delivery.metadata == %{}
      assert delivery.config == [test_key: "test_value"]
    end

    test "sends calm message after resolution period" do
      :telemetry.execute([:test, :custom], %{value: 15}, %{})
      Process.sleep(10)

      :telemetry.execute([:test, :custom], %{value: 5}, %{})

      Process.sleep(60)

      :telemetry.execute([:test, :custom], %{value: 5}, %{})
      Process.sleep(50)

      deliveries = CustomTestNotifier.get_deliveries()
      assert length(deliveries) == 2
      [alert, calm] = deliveries
      assert alert.message =~ "CUSTOM ALERT: 15"
      assert calm.message =~ "CUSTOM CALM: 5"
    end
  end

  defp count_occurrences(string, substring) do
    string |> String.split(substring) |> length() |> Kernel.-(1)
  end
end
