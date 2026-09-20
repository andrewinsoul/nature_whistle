defmodule NatureWhistle.Packs.Beam.CollectorTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Packs.Beam.Collector

  test "starts with the default configuration" do
    state = :sys.get_state(Collector)

    assert state.interval_ms == 5_000

    assert Enum.sort(state.metrics) ==
             Enum.sort([
               :memory,
               :run_queue,
               :process_memory,
               :ets_memory,
               :binary_memory,
               :process_count,
               :atom_count,
               :port_count
             ])
  end
end
