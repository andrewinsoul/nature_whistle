defmodule NatureWhistle.FailureTrackerTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.FailureTracker
  import ExUnit.CaptureLog

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

  test "sweep reports recovery when an active window retains recent failures below threshold" do
    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 3, 100, 0)
    assert {:below_threshold, 2} = FailureTracker.record_failure(:alert, :key, 3, 100, 50)
    assert {:triggered, 3} = FailureTracker.record_failure(:alert, :key, 3, 100, 80)

    assert [{:alert, :key}] = FailureTracker.sweep(120)

    assert {:triggered, 3} = FailureTracker.record_failure(:alert, :key, 3, 100, 130)
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

  test "reports whether another failure key remains active during recovery" do
    parent = self()
    original_handler = :sys.get_state(FailureTracker).recovery_handler

    :sys.replace_state(FailureTracker, fn state ->
      %{state | recovery_handler: fn recovery -> send(parent, {:recovery, recovery}) end}
    end)

    on_exit(fn ->
      :sys.replace_state(FailureTracker, fn state ->
        %{state | recovery_handler: original_handler}
      end)
    end)

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :first, 2, 50, 0)
    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :first, 2, 50, 0)

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :second, 2, 50, 80)
    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :second, 2, 50, 80)

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :inactive, 2, 50, 100)

    assert [{:alert, :first}] = FailureTracker.sweep(100)
    assert_receive {:recovery, {:alert, :first, true}}

    assert [{:alert, :second}] = FailureTracker.sweep(140)
    assert_receive {:recovery, {:alert, :second, false}}
  end

  test "does not invoke a nil recovery handler" do
    original_handler = :sys.get_state(FailureTracker).recovery_handler

    :sys.replace_state(FailureTracker, fn state ->
      %{state | recovery_handler: nil}
    end)

    on_exit(fn ->
      :sys.replace_state(FailureTracker, fn state ->
        %{state | recovery_handler: original_handler}
      end)
    end)

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 2, 100, 0)
    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :key, 2, 100, 50)
    assert [{:alert, :key}] = FailureTracker.sweep(151)
  end

  test "logs and continues when the recovery handler raises" do
    original_handler = :sys.get_state(FailureTracker).recovery_handler

    :sys.replace_state(FailureTracker, fn state ->
      %{state | recovery_handler: fn _recovery -> raise "callback failed" end}
    end)

    on_exit(fn ->
      :sys.replace_state(FailureTracker, fn state ->
        %{state | recovery_handler: original_handler}
      end)
    end)

    assert {:below_threshold, 1} = FailureTracker.record_failure(:alert, :key, 2, 100, 0)
    assert {:triggered, 2} = FailureTracker.record_failure(:alert, :key, 2, 100, 50)

    log =
      capture_log(fn ->
        assert [{:alert, :key}] = FailureTracker.sweep(151)
      end)

    assert log =~ "NatureWhistle aggregate recovery callback failed"
    assert log =~ "callback failed"
  end

  test "requires a valid recovery handler" do
    assert {:ok, state} = FailureTracker.init(recovery_handler: nil, sweep_interval_ms: 60_000)
    assert state.recovery_handler == nil

    assert_raise ArgumentError, ":recovery_handler must be a one-argument function", fn ->
      FailureTracker.init(recovery_handler: :invalid, sweep_interval_ms: 60_000)
    end
  end

  test "requires a positive sweep interval" do
    assert_raise ArgumentError, ":sweep_interval_ms must be a positive integer", fn ->
      FailureTracker.init(sweep_interval_ms: 0)
    end
  end
end
