defmodule NatureWhistle.MailboxMonitor do
  @moduledoc """
  Supervised BEAM mailbox saturation monitor.

  The monitor owns the VM-wide `:long_message_queue` system-monitor
  option when configured with `:own` mode. It emits immediate saturation
  events, delayed stall events, and recovery events for processes whose
  message queues cross the configured thresholds.

  The BEAM system monitor is node-local and has a single owner per VM.
  This process never replaces an existing owner. On OTP versions without
  long-message-queue support, the process declines to start instead of
  making the application fail.
  """

  use GenServer

  require Logger

  @saturated_event [:nature_whistle, :vm, :mailbox, :saturated]
  @stall_event [:nature_whistle, :vm, :mailbox, :stall]
  @recovered_event [:nature_whistle, :vm, :mailbox, :recovered]
  @dead_event [:nature_whistle, :vm, :mailbox, :dead]

  @default_threshold 1_000
  @default_disable_threshold 900
  @default_duration_ms 90_000
  @default_hysteresis @default_threshold - @default_disable_threshold
  @default_enrich [
    :current_function,
    :status,
    :message_queue_len,
    :total_heap_size
  ]

  @supported_enrichment_keys [
    :current_function,
    :current_stacktrace,
    :status,
    :message_queue_len,
    :dictionary,
    :total_heap_size
  ]

  @doc """
  Starts the mailbox monitor.

  Supported options are:

  - `:mode` - `:own` or `:disabled`; defaults to `:own`
  - `:threshold` - queue length that enters saturation; defaults to `1_000`
  - `:disable_threshold` - queue length that leaves saturation; defaults to `900`
  - `:duration_ms` - sustained saturation period before `:stall`; defaults to
    `90_000`
  - `:enrich` - safe process information keys to include in telemetry metadata
  """
  def start_link(opts \\ []) do
    name =
      if is_map(opts) do
        Map.get(opts, :name, __MODULE__)
      else
        Keyword.get(opts, :name, __MODULE__)
      end

    gen_server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @impl true
  def init(opts) do
    opts = normalize_options!(opts)

    case opts.mode do
      :disabled ->
        :ignore

      :own ->
        case claim_system_monitor(opts) do
          {:ok, previous_monitor} ->
            {:ok,
             %{
               options: opts,
               previous_monitor: previous_monitor,
               monitor_claimed?: true,
               pending: %{}
             }}

          result ->
            handle_claim_failure(result)
        end
    end
  end

  defp handle_claim_failure(:conflict) do
    Logger.warning(
      "NatureWhistle mailbox monitoring disabled because another system monitor is already active"
    )

    :ignore
  end

  defp handle_claim_failure(:unsupported) do
    Logger.warning("NatureWhistle mailbox monitoring is unavailable on this OTP/ERTS version")

    :ignore
  end

  @impl true
  def handle_info({:monitor, pid, :long_message_queue, true}, state) when is_pid(pid) do
    if Map.has_key?(state.pending, pid) do
      {:noreply, state}
    else
      monitor_ref = Process.monitor(pid)
      token = make_ref()

      timer_ref =
        Process.send_after(self(), {:mailbox_stall, pid, token}, state.options.duration_ms)

      emit_event(@saturated_event, pid, true, state.options.enrich)

      pending_entry = %{
        monitor_ref: monitor_ref,
        timer_ref: timer_ref,
        token: token,
        stalled?: false
      }

      {:noreply, %{state | pending: Map.put(state.pending, pid, pending_entry)}}
    end
  end

  @impl true
  def handle_info({:monitor, pid, :long_message_queue, false}, state) when is_pid(pid) do
    {entry, pending} = Map.pop(state.pending, pid)

    if entry do
      cancel_pending(entry)
      emit_event(@recovered_event, pid, false, state.options.enrich)
    end

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_info({:mailbox_stall, pid, token}, state) when is_pid(pid) do
    case Map.get(state.pending, pid) do
      %{token: ^token, stalled?: false} = entry ->
        emit_event(@stall_event, pid, true, state.options.enrich)
        pending = Map.put(state.pending, pid, %{entry | stalled?: true})
        {:noreply, %{state | pending: pending}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    case Map.get(state.pending, pid) do
      %{monitor_ref: ^monitor_ref} = entry ->
        cancel_timer(entry.timer_ref)

        emit_event(
          @dead_event,
          pid,
          false,
          state.options.enrich,
          %{reason: reason}
        )

        {:noreply, %{state | pending: Map.delete(state.pending, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{monitor_claimed?: true} = state) do
    restore_owned_system_monitor(state.previous_monitor)
    Enum.each(state.pending, fn {_pid, entry} -> cancel_pending(entry) end)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp normalize_options!(opts) when is_map(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1) do
      opts
      |> Map.to_list()
      |> normalize_options!()
    else
      raise ArgumentError, "mailbox monitor options map must have atom keys"
    end
  end

  defp normalize_options!(opts) when is_list(opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    default_disable_threshold =
      if is_integer(threshold) and threshold > 0 do
        max(0, threshold - @default_hysteresis)
      else
        @default_disable_threshold
      end

    disable_threshold = Keyword.get(opts, :disable_threshold, default_disable_threshold)

    mode = Keyword.get(opts, :mode, :own)
    duration_ms = Keyword.get(opts, :duration_ms, @default_duration_ms)
    enrich = Keyword.get(opts, :enrich, @default_enrich)

    unless mode in [:own, :disabled] do
      raise ArgumentError, "mailbox monitor mode must be :own or :disabled"
    end

    unless is_integer(threshold) and threshold > 0 do
      raise ArgumentError, "mailbox monitor threshold must be a positive integer"
    end

    unless is_integer(disable_threshold) and
             disable_threshold >= 0 and disable_threshold < threshold do
      raise ArgumentError,
            "mailbox monitor disable_threshold must be an integer smaller than threshold"
    end

    unless is_integer(duration_ms) and duration_ms >= 0 do
      raise ArgumentError, "mailbox monitor duration_ms must be a non-negative integer"
    end

    unless is_list(enrich) and Enum.all?(enrich, &(&1 in @supported_enrichment_keys)) do
      raise ArgumentError,
            "mailbox monitor enrich contains an unsupported process information key"
    end

    %{
      mode: mode,
      threshold: threshold,
      disable_threshold: disable_threshold,
      duration_ms: duration_ms,
      enrich: Enum.uniq(enrich)
    }
  end

  defp normalize_options!(_opts) do
    raise ArgumentError, "mailbox monitor options must be a keyword list or map with atom keys"
  end

  defp claim_system_monitor(opts) do
    monitor_option =
      {:long_message_queue, {opts.disable_threshold, opts.threshold}}

    case :erlang.system_monitor() do
      :undefined ->
        attempt_system_monitor_claim(monitor_option)

      _existing_monitor ->
        :conflict
    end
  end

  defp attempt_system_monitor_claim(monitor_option) do
    try do
      case :erlang.system_monitor(self(), [monitor_option]) do
        :undefined ->
          {:ok, :undefined}

        previous_monitor ->
          rollback_system_monitor_claim(previous_monitor)
          :conflict
      end
    rescue
      ArgumentError ->
        :unsupported
    catch
      :error, :badarg ->
        :unsupported
    end
  end

  defp rollback_system_monitor_claim(previous_monitor) do
    restore_system_monitor(previous_monitor)
  rescue
    exception ->
      Logger.warning(
        "NatureWhistle could not restore the previous system monitor: #{inspect(exception)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "NatureWhistle could not restore the previous system monitor: " <>
          "#{inspect({kind, reason})}"
      )
  end

  defp restore_owned_system_monitor(previous_monitor) do
    case :erlang.system_monitor() do
      {pid, _options} when pid == self() ->
        restore_system_monitor(previous_monitor)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp restore_system_monitor(:undefined), do: :erlang.system_monitor(:undefined)
  defp restore_system_monitor({pid, options}), do: :erlang.system_monitor(pid, options)

  defp cancel_pending(entry) do
    cancel_timer(entry.timer_ref)
    Process.demonitor(entry.monitor_ref, [:flush])
  end

  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)

  defp emit_event(event, pid, monitor_state, enrich_keys, extra_metadata \\ %{}) do
    {message_queue_len, process_info} = process_snapshot(pid, enrich_keys)

    measurements = %{message_queue_len: message_queue_len}

    metadata =
      %{
        pid: pid,
        monitor_state: monitor_state,
        process_info: process_info
      }
      |> Map.merge(extra_metadata)

    try do
      :telemetry.execute(event, measurements, metadata)
    rescue
      exception ->
        Logger.error("NatureWhistle mailbox telemetry emission failed: #{inspect(exception)}")
    end
  end

  defp process_snapshot(pid, enrich_keys) do
    info_keys = Enum.uniq([:message_queue_len | enrich_keys])

    case Process.info(pid, info_keys) do
      nil ->
        {nil, %{}}

      info when is_list(info) ->
        info_map = Map.new(info)
        process_info = Map.take(info_map, enrich_keys)
        {Map.get(info_map, :message_queue_len), process_info}
    end
  end
end
