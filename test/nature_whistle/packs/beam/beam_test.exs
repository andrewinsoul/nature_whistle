defmodule NatureWhistle.Packs.BeamTest do
  use ExUnit.Case, async: true

  alias NatureWhistle.Packs.Beam

  test "returns the default BEAM alerts" do
    alerts = Beam.alerts([])

    assert Enum.map(alerts, & &1.id) == [
             :high_memory,
             :high_cpu,
             :high_process_memory,
             :high_ets_memory,
             :high_binary_memory,
             :high_process_count,
             :high_atom_count,
             :high_port_count
           ]
  end

  test "configures the high memory alert" do
    [alert] =
      Beam.alerts([])
      |> Enum.filter(&(&1.id == :high_memory))

    assert alert.event == [:vm, :memory, :total]
    assert alert.threshold == 1_073_741_824
    assert alert.debounce_ms == 300_000
    assert alert.notifier == :console
  end

  test "configures the high CPU run-queue alert" do
    [alert] =
      Beam.alerts([])
      |> Enum.filter(&(&1.id == :high_cpu))

    assert alert.event == [:vm, :total_run_queue_lengths, :total]
    assert alert.threshold == 4
    assert alert.debounce_ms == 60_000
    assert alert.notifier == :console

    assert alert.rate_limit == [
             window_ms: 60_000,
             max_events: 10
           ]

    assert alert.sliding_window == [
             window_ms: 30_000,
             max_events: 3
           ]
  end

  test "returns the metrics required by BEAM alerts" do
    assert Beam.metrics(Beam.alerts([])) == [
             :memory,
             :run_queue,
             :process_memory,
             :ets_memory,
             :binary_memory,
             :process_count,
             :atom_count,
             :port_count
           ]
  end

  test "deduplicates metrics that use the same telemetry event" do
    alerts = [
      %{event: [:vm, :memory, :total]},
      %{event: [:vm, :memory, :total]},
      %{event: [:vm, :processes, :count]}
    ]

    assert Beam.metrics(alerts) == [
             :memory,
             :process_count
           ]
  end

  test "collect/0 emits total memory measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :memory, :total]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :memory, :total],
      _handler_id,
      %{total: total},
      %{}
    }

    assert is_integer(total)
    assert total > 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits process memory measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :memory, :processes]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :memory, :processes],
      _handler_id,
      %{processes: processes},
      %{}
    }

    assert is_integer(processes)
    assert processes >= 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits ETS memory measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :memory, :ets]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :memory, :ets],
      _handler_id,
      %{ets: ets},
      %{}
    }

    assert is_integer(ets)
    assert ets >= 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits binary memory measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :memory, :binary]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :memory, :binary],
      _handler_id,
      %{binary: binary},
      %{}
    }

    assert is_integer(binary)
    assert binary >= 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits process count measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :processes, :count]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :processes, :count],
      _handler_id,
      %{count: count},
      %{}
    }

    assert is_integer(count)
    assert count > 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits atom count measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :atoms, :count]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :atoms, :count],
      _handler_id,
      %{count: count},
      %{}
    }

    assert is_integer(count)
    assert count > 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits port count measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :ports, :count]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :ports, :count],
      _handler_id,
      %{count: count},
      %{}
    }

    assert is_integer(count)
    assert count >= 0

    :telemetry.detach(ref)
  end

  test "collect/0 emits total run queue measurement" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:vm, :total_run_queue_lengths, :total]
      ])

    assert :ok = Beam.collect()

    assert_receive {
      [:vm, :total_run_queue_lengths, :total],
      _handler_id,
      %{total: total},
      %{}
    }

    assert is_integer(total)
    assert total >= 0

    :telemetry.detach(ref)
  end

  test "overrides alert thresholds" do
    alerts = Beam.alerts(thresholds: [memory: 123])

    high_memory = Enum.find(alerts, &(&1.id == :high_memory))

    assert high_memory.threshold == 123
  end

  test "disables an alert metric" do
    alerts = Beam.alerts(thresholds: [process_count: false])

    refute Enum.any?(alerts, &(&1.id == :high_process_count))
  end

  test "keeps unspecified thresholds at their defaults" do
    alerts = Beam.alerts(thresholds: [memory: 123])

    high_memory = Enum.find(alerts, &(&1.id == :high_memory))
    high_process_count = Enum.find(alerts, &(&1.id == :high_process_count))

    assert high_memory.threshold == 123
    assert high_process_count.threshold == 50_000
  end
end
