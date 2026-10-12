defmodule NatureWhistle.Packs.Beam.CollectorTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.Packs.Beam.Collector

  setup do
    original_alerts = Application.get_env(:nature_whistle, :alerts)
    Application.delete_env(:nature_whistle, :alerts)
    NatureWhistle.Setup.init()
    NatureWhistle.Setup.sync_beam_collector()

    on_exit(fn ->
      case original_alerts do
        nil -> Application.delete_env(:nature_whistle, :alerts)
        alerts -> Application.put_env(:nature_whistle, :alerts, alerts)
      end

      NatureWhistle.Setup.init()
      NatureWhistle.Setup.sync_beam_collector()
    end)

    :ok
  end

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
