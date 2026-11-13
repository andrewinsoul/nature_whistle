defmodule NatureWhistle.MailboxMonitorTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.MailboxMonitor

  @saturated_event [:nature_whistle, :vm, :mailbox, :saturated]
  @stall_event [:nature_whistle, :vm, :mailbox, :stall]
  @recovered_event [:nature_whistle, :vm, :mailbox, :recovered]
  @dead_event [:nature_whistle, :vm, :mailbox, :dead]

  setup_all do
    case :erlang.system_monitor() do
      :undefined ->
        case MailboxMonitor.start_link(threshold: 10, disable_threshold: 5, duration_ms: 1) do
          {:ok, pid} ->
            GenServer.stop(pid)
            :ok

          :ignore ->
            {:skip, "long_message_queue is not supported by this OTP/ERTS version"}
        end

      _settings ->
        {:skip, "another system monitor is active in the test VM"}
    end
  end

  setup do
    {:ok, monitor} =
      MailboxMonitor.start_link(
        threshold: 10,
        disable_threshold: 5,
        duration_ms: 40,
        enrich: [:current_function, :status, :message_queue_len, :total_heap_size]
      )

    on_exit(fn ->
      if Process.alive?(monitor), do: GenServer.stop(monitor)
    end)

    {:ok, monitor: monitor}
  end

  test "emits saturated, sustained stall, and recovered events", %{monitor: monitor} do
    ref = attach_events()
    worker = idle_worker()

    send(monitor, {:monitor, worker, :long_message_queue, true})

    assert_receive {@saturated_event, _handler_id, %{message_queue_len: _}, %{pid: ^worker}}
    assert_receive {@stall_event, _handler_id, %{message_queue_len: _}, %{pid: ^worker}}, 200

    send(monitor, {:monitor, worker, :long_message_queue, false})

    assert_receive {@recovered_event, _handler_id, %{message_queue_len: _}, %{pid: ^worker}}

    :telemetry.detach(ref)
    Process.exit(worker, :kill)
  end

  test "cancels a pending stall when the process recovers early", %{monitor: monitor} do
    ref = attach_events()
    worker = idle_worker()

    send(monitor, {:monitor, worker, :long_message_queue, true})
    assert_receive {@saturated_event, _handler_id, _, %{pid: ^worker}}

    send(monitor, {:monitor, worker, :long_message_queue, false})
    assert_receive {@recovered_event, _handler_id, _, %{pid: ^worker}}
    refute_receive {@stall_event, _handler_id, _, %{pid: ^worker}}, 100

    :telemetry.detach(ref)
    Process.exit(worker, :kill)
  end

  test "detects a real mailbox spike and emits saturation and recovery events",
       %{monitor: monitor} do
    ref = attach_events()
    test_pid = self()

    worker =
      spawn(fn ->
        receive do
          :drain ->
            drain_mailbox = fn drain_mailbox ->
              receive do
                {:queued_message, _n} ->
                  drain_mailbox.(drain_mailbox)
              after
                0 ->
                  send(test_pid, :mailbox_drained)

                  receive do
                    :stop -> :ok
                  end
              end
            end

            drain_mailbox.(drain_mailbox)

          :stop ->
            :ok
        end
      end)

    try do
      Enum.each(1..20, fn n ->
        send(worker, {:queued_message, n})
      end)

      assert_receive {
                       @saturated_event,
                       _handler_id,
                       %{message_queue_len: queue_length},
                       %{pid: ^worker}
                     },
                     2_000

      assert queue_length >= 10

      send(worker, :drain)

      assert_receive :mailbox_drained, 2_000

      assert_receive {
                       @recovered_event,
                       _handler_id,
                       _measurements,
                       %{pid: ^worker}
                     },
                     2_000
    after
      if Process.alive?(worker) do
        send(worker, :stop)
      end

      :telemetry.detach(ref)
    end

    assert Process.alive?(monitor)
  end

  test "treats process death as a terminal outcome", %{monitor: monitor} do
    ref = attach_events()
    worker = idle_worker()

    send(monitor, {:monitor, worker, :long_message_queue, true})
    assert_receive {@saturated_event, _handler_id, _, %{pid: ^worker}}

    Process.exit(worker, :kill)

    assert_receive {
                     @dead_event,
                     _handler_id,
                     _,
                     %{pid: ^worker, reason: :killed}
                   },
                   200

    :telemetry.detach(ref)
  end

  test "default enrichment excludes stacktraces and dictionaries", %{monitor: monitor} do
    ref = attach_events()
    worker = idle_worker()

    send(monitor, {:monitor, worker, :long_message_queue, true})

    assert_receive {
      @saturated_event,
      _handler_id,
      %{message_queue_len: _},
      %{process_info: process_info}
    }

    assert Map.has_key?(process_info, :current_function)
    assert Map.has_key?(process_info, :status)
    assert Map.has_key?(process_info, :total_heap_size)
    refute Map.has_key?(process_info, :current_stacktrace)
    refute Map.has_key?(process_info, :dictionary)

    :telemetry.detach(ref)
    Process.exit(worker, :kill)
  end

  test "ignores duplicate saturation, stale timers, unmatched recovery, and unknown messages", %{
    monitor: monitor
  } do
    ref = attach_events()
    worker = idle_worker()
    self_pid = self()

    :sys.replace_state(monitor, fn state ->
      %{state | options: %{state.options | duration_ms: 500}}
    end)

    send(monitor, {:monitor, worker, :long_message_queue, true})
    assert_receive {@saturated_event, _handler_id, _, %{pid: ^worker}}

    send(monitor, {:monitor, worker, :long_message_queue, true})
    refute_receive {@saturated_event, _handler_id, _, %{pid: ^worker}}, 20

    state = :sys.get_state(monitor)
    token = state.pending |> Map.fetch!(worker) |> Map.fetch!(:token)

    send(monitor, {:monitor, self(), :long_message_queue, false})
    send(monitor, {:DOWN, make_ref(), :process, worker, :normal})
    send(monitor, :unrecognized_message)
    refute_receive {@recovered_event, _handler_id, _, %{pid: ^self_pid}}, 20

    send(monitor, {:monitor, worker, :long_message_queue, false})
    assert_receive {@recovered_event, _handler_id, _, %{pid: ^worker}}

    send(monitor, {:mailbox_stall, worker, token})
    refute_receive {@stall_event, _handler_id, _, %{pid: ^worker}}, 80

    :telemetry.detach(ref)
    Process.exit(worker, :kill)
  end

  test "validates monitor options before claiming ownership" do
    assert :ignore = MailboxMonitor.init(%{mode: :disabled})

    assert_raise ArgumentError, ~r/mode must be :own or :disabled/, fn ->
      MailboxMonitor.init(mode: :attach)
    end

    assert_raise ArgumentError, ~r/threshold must be a positive integer/, fn ->
      MailboxMonitor.init(threshold: 0)
    end

    assert_raise ArgumentError, ~r/disable_threshold must be an integer/, fn ->
      MailboxMonitor.init(threshold: 5, disable_threshold: 5)
    end

    assert_raise ArgumentError, ~r/duration_ms must be a non-negative integer/, fn ->
      MailboxMonitor.init(duration_ms: -1)
    end

    assert_raise ArgumentError, ~r/enrich contains an unsupported/, fn ->
      MailboxMonitor.init(enrich: [:not_a_process_info_key])
    end

    assert_raise ArgumentError, ~r/options must be a keyword list or map/, fn ->
      MailboxMonitor.init(:invalid)
    end
  end

  defp attach_events do
    :telemetry_test.attach_event_handlers(self(), [
      @saturated_event,
      @stall_event,
      @recovered_event,
      @dead_event
    ])
  end

  defp idle_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end

defmodule NatureWhistle.MailboxMonitorOwnershipTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.MailboxMonitor

  test "own mode does not replace an existing system monitor" do
    case MailboxMonitor.start_link(
           name: :nature_whistle_mailbox_monitor_owner,
           threshold: 10,
           disable_threshold: 5,
           duration_ms: 40
         ) do
      {:ok, owner} ->
        on_exit(fn ->
          if Process.alive?(owner), do: GenServer.stop(owner)
        end)

        assert :ignore =
                 MailboxMonitor.start_link(
                   name: :nature_whistle_mailbox_monitor_candidate,
                   threshold: 10,
                   disable_threshold: 5,
                   duration_ms: 40
                 )

      :ignore ->
        :ok
    end
  end
end
