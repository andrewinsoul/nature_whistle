defmodule NatureWhistle.Packs.Beam.CollectorTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Packs.Beam.Collector

  setup do
    original_state = :sys.get_state(Collector)

    on_exit(fn ->
      :ok = Collector.configure(original_state.metrics)
    end)

    :ok
  end

  test "starts with the default configuration" do
    state = :sys.get_state(Collector)

    assert state.interval_ms == 5_000
    assert state.metrics == []
  end

  test "configures the metrics to collect" do
    assert :ok = Collector.configure([:memory, :process_count])

    state = :sys.get_state(Collector)

    assert state.metrics == [:memory, :process_count]
  end

  test "collector only collects configured metrics" do
    assert :ok = Collector.configure([:process_count])

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :processes, :count],
        [:vm, :memory, :total]
      ])

    send(Collector, :collect)

    assert_receive {
      [:vm, :processes, :count],
      _handler_id,
      %{count: count},
      %{}
    }

    refute_receive {
      [:vm, :memory, :total],
      _handler_id,
      _measurements,
      _metadata
    }

    assert is_integer(count)
    assert count > 0

    :telemetry.detach(ref)
  end
end
