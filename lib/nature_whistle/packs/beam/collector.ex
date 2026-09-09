defmodule NatureWhistle.Packs.Beam.Collector do
  use GenServer

  @default_interval_ms 5_000

  @doc """
  Starts the supervised BEAM metric collector.

  Supported options:

  - `:interval_ms` - collection interval in milliseconds; defaults to `5_000`
  - `:metrics` - initial list of BEAM metrics to collect; defaults to `[]`

  The collector is normally started by `NatureWhistle.Application`.
  """
  def start_link(opts \\ []) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    metrics = Keyword.get(opts, :metrics, [])

    GenServer.start_link(
      __MODULE__,
      {interval_ms, metrics},
      name: __MODULE__
    )
  end

  @doc """
  Replaces the set of BEAM metrics collected by the running collector.

  The list should contain metric identifiers supported by
  `NatureWhistle.Packs.Beam.collect/1`. Returns `:ok` after the collector state
  has been updated.
  """
  def configure(metrics) when is_list(metrics) do
    GenServer.call(__MODULE__, {:configure, metrics})
  end

  @impl true
  def init({interval_ms, metrics}) do
    schedule_collect(interval_ms)

    {:ok, %{interval_ms: interval_ms, metrics: metrics}}
  end

  @impl true
  def handle_call({:configure, metrics}, _from, state) do
    {:reply, :ok, %{state | metrics: metrics}}
  end

  @impl true
  def handle_info(:collect, state) do
    NatureWhistle.Packs.Beam.collect(state.metrics)

    schedule_collect(state.interval_ms)

    {:noreply, state}
  end

  defp schedule_collect(interval_ms) do
    Process.send_after(self(), :collect, interval_ms)
  end
end
