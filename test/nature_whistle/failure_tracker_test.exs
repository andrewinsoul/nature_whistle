defmodule NatureWhistle.FailureTrackerTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.FailureTracker

  setup do
    :ok = FailureTracker.reset()

    :ok
  end

  test "returns below_threshold until the failure threshold is reached" do
    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 0)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 100)
  end

  test "returns active for additional failures after an alert is triggered" do
    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 0)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 100)

    assert {:active, 3} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 200)
  end

  test "expires failures outside the aggregation window" do
    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 2, 100, 0)
    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :key, 2, 100, 50)

    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 100, 151)
  end

  test "keeps aggregation state independent for different keys" do
    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :first, 2, 1_000, 0)
    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :second, 2, 1_000, 10)

    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :first, 2, 1_000, 20)
    assert {:below_threshold, 2} = FailureTracker.record_failure(:alert, :second, 3, 1_000, 30)
  end

  test "keeps aggregation state independent for different alert ids" do
    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:first_alert, :key, 2, 1_000, 0)

    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:second_alert, :key, 2, 1_000, 10)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:first_alert, :key, 2, 1_000, 20)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:second_alert, :key, 2, 1_000, 30)
  end

  test "sweep reports recovery when an active window falls below the threshold" do
    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 100, 0)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:alert, :key, 2, 100, 50)

    assert [{:alert, :key}] =
             FailureTracker.sweep(151)
  end

  test "sweep does not report inactive windows as recovered" do
    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 3, 100, 0)

    assert FailureTracker.sweep(101) == []

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 3, 100, 200)
  end

  test "reset clears all tracked failure windows" do
    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 0)

    assert {:triggered, 2} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 100)

    assert :ok = FailureTracker.reset()

    assert {:below_threshold, 1} =
             FailureTracker.record_failure(:alert, :key, 2, 1000, 200)
  end

  test "requires a positive failure threshold" do
    assert_raise ArgumentError, ":failures must be a positive integer", fn ->
      FailureTracker.record_failure(:alert, :key, 0, 1_000, 0)
    end

    assert_raise ArgumentError, ":failures must be a positive integer", fn ->
      FailureTracker.record_failure(:alert, :key, -1, 1_000, 0)
    end
  end

  test "requires a positive aggregation window" do
    assert_raise ArgumentError, ":within_ms must be a positive integer", fn ->
      FailureTracker.record_failure(:alert, :key, 2, 0, 0)
    end

    assert_raise ArgumentError, ":within_ms must be a positive integer", fn ->
      FailureTracker.record_failure(:alert, :key, 2, -1, 0)
    end
  end

  test "requires a positive sweep interval" do
    assert_raise ArgumentError, ":sweep_interval_ms must be a positive integer", fn ->
      FailureTracker.init(sweep_interval_ms: 0)
    end
  end
end
