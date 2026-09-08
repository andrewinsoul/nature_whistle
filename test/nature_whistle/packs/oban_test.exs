defmodule NatureWhistle.Packs.ObanTest do
  use ExUnit.Case, async: true

  alias NatureWhistle.Packs.Oban

  test "returns the default Oban alerts" do
    alerts = Oban.alerts([])

    assert Enum.map(alerts, & &1.id) == [
             :nature_whistle_oban_slow_job,
             :nature_whistle_oban_slow_queue,
             :nature_whistle_oban_job_exception
           ]
  end

  test "configures slow job with the default duration threshold" do
    [alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_slow_job))

    assert alert.event == [:oban, :job, :stop]
    assert alert.condition == :metric
    assert alert.measurement_key == :duration
    assert alert.threshold == 5_000_000_000
  end

  test "configures slow queue with the default queue time threshold" do
    [alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_slow_queue))

    assert alert.event == [:oban, :job, :stop]
    assert alert.condition == :metric
    assert alert.measurement_key == :queue_time
    assert alert.threshold == 1_000_000_000
  end

  test "configures job exception as an event alert" do
    [alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_job_exception))

    assert alert.event == [:oban, :job, :exception]
    assert alert.condition == :event
  end

  test "configures job exception correlation" do
    [alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_job_exception))

    assert %{correlation: correlation} = alert

    assert is_function(correlation.key, 1)
    assert correlation.recovery_event == [:oban, :job, :stop]
    assert is_function(correlation.recovery?, 1)
  end

  test "configures job exception message formatting" do
    [alert] =
      Oban.alerts([])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_job_exception))

    assert is_function(alert.message_formatter, 1)

    metadata = %{
      job: %{
        id: 456,
        worker: "MyApp.Workers.EmailWorker",
        queue: "default"
      }
    }

    assert alert.message_formatter.(metadata) == %{
             job_id: 456,
             worker: "MyApp.Workers.EmailWorker",
             queue: "default"
           }
  end

  test "uses a custom slow job threshold" do
    [alert] =
      Oban.alerts(thresholds: [slow_job: 10_000])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_slow_job))

    assert alert.threshold == 10_000_000_000
  end

  test "uses a custom slow queue threshold" do
    [alert] =
      Oban.alerts(thresholds: [slow_queue: 2_500])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_slow_queue))

    assert alert.threshold == 2_500_000_000
  end

  test "disables slow job alert when threshold is false" do
    alerts = Oban.alerts(thresholds: [slow_job: false])

    refute Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_slow_job)
           )

    assert Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_slow_queue)
           )

    assert Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_job_exception)
           )
  end

  test "disables slow queue alert when threshold is false" do
    alerts = Oban.alerts(thresholds: [slow_queue: false])

    refute Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_slow_queue)
           )

    assert Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_slow_job)
           )

    assert Enum.any?(
             alerts,
             &(&1.id == :nature_whistle_oban_job_exception)
           )
  end

  test "does not generate an aggregate alert when failure detection is disabled" do
    alerts = Oban.alerts([])

    refute Enum.any?(alerts, fn alert ->
             match?({:aggregate, _}, alert.condition)
           end)
  end

  test "generates an aggregate alert when failure detection is enabled" do
    alerts =
      Oban.alerts(
        failure_detection: [
          failures: 3,
          within_ms: 60_000
        ]
      )

    [alert] =
      Enum.filter(
        alerts,
        &(&1.id == :nature_whistle_oban_repeated_job_failures)
      )

    assert alert.event == [:oban, :job, :exception]
    assert alert.measurement_key == :failure_count
    assert alert.threshold == 3

    assert {:aggregate, aggregate} = alert.condition

    assert aggregate[:failures] == 3
    assert aggregate[:within_ms] == 60_000
    assert aggregate[:measurement_key] == :failure_count
    assert is_function(aggregate[:key], 1)
  end

  test "uses the default failure detection window" do
    [alert] =
      Oban.alerts(failure_detection: [failures: 3])
      |> Enum.filter(&(&1.id == :nature_whistle_oban_repeated_job_failures))

    assert {:aggregate, aggregate} = alert.condition
    assert aggregate[:within_ms] == 300_000
  end

  test "builds a failure key from Oban job metadata" do
    metadata = %{
      job: %{
        id: 456,
        worker: "MyApp.Workers.EmailWorker",
        queue: "default"
      }
    }

    assert Oban.failure_key(metadata) ==
             {456, "MyApp.Workers.EmailWorker", "default"}
  end

  test "identifies a successful Oban stop" do
    assert Oban.successful_stop?(%{state: :success})
  end

  test "does not identify a non-successful Oban stop as recovery" do
    refute Oban.successful_stop?(%{state: :retryable})
    refute Oban.successful_stop?(%{state: :discard})
  end

  test "builds notification metadata from an Oban job" do
    metadata = %{
      job: %{
        id: 456,
        worker: "MyApp.Workers.EmailWorker",
        queue: "default"
      }
    }

    assert Oban.notification_metadata(metadata) == %{
             job_id: 456,
             worker: "MyApp.Workers.EmailWorker",
             queue: "default"
           }
  end
end
