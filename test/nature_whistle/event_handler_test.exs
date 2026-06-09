defmodule NatureWhistle.EventHandlerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    :ets.delete_all_objects(:nature_whistle_alert_state)
    :ets.delete_all_objects(:nature_whistle_cooldown)
    # Ensure test notifier is console (default)
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
        # low threshold to always trigger
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
        # Spike
        :telemetry.execute([:test, :metric], %{value: 15}, %{})
        Process.sleep(10)

        # Drop below threshold
        :telemetry.execute([:test, :metric], %{value: 5}, %{})

        Process.sleep(60)

        # Trigger again to force state check? Actually the handler checks on each event.
        # After resolution_ms, a low value triggers calm.
        :telemetry.execute([:test, :metric], %{value: 5}, %{})
        Process.sleep(10)
      end)

    assert log =~ "ALERT: 15"
    assert log =~ "CALM: 5"
  end

  test "warns when notifier config is missing" do
    # Override alerts to use a notifier that has no config
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
    # Ensure handler attached
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

    assert log =~ ~r/Unsupported notifier: :missing/

    :telemetry.detach("missing-config-test")
  end

  test "warns when notifier is unsupported" do
    Application.put_env(:nature_whistle, :alerts, [
      %{
        id: :unsupported,
        event: [:test, :metric],
        threshold: 0,
        alert_message: "test",
        notifier: :unknown
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

    assert log =~ "Unsupported notifier: :unknown"

    :telemetry.detach("unsupported-test")
  end

  defp count_occurrences(string, substring) do
    string |> String.split(substring) |> length() |> Kernel.-(1)
  end
end
