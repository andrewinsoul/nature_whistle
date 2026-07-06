defmodule NatureWhistle.EventGuardTest do
  use ExUnit.Case, async: false

  alias NatureWhistle.EventGuard

  @table :nature_whistle_rate_limit

  setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:ordered_set, :public, :named_table])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  test "allow_rate_limit?/2 allows events when the window is empty" do
    alert = %{id: :cpu_alert, rate_limit: [window_ms: 1_000, max_events: 2]}

    assert EventGuard.allow_rate_limit?(alert, 10_000)
  end

  test "allow_rate_limit?/2 blocks events once the configured window is full" do
    alert = %{id: :cpu_alert, rate_limit: [window_ms: 1_000, max_events: 2]}
    :ets.insert(@table, {{:rate_limit, :cpu_alert}, [9_900, 9_950]})

    refute EventGuard.allow_rate_limit?(alert, 10_000)
  end

  test "record_rate_limit/2 prepends timestamps into the ETS bucket" do
    alert = %{id: :cpu_alert}

    EventGuard.record_rate_limit(alert, 10_000)
    EventGuard.record_rate_limit(alert, 10_250)

    assert :ets.lookup(@table, {:rate_limit, :cpu_alert}) == [
             {{:rate_limit, :cpu_alert}, [10_250, 10_000]}
           ]
  end

  test "allow_sliding_window?/2 respects the rolling bucket count" do
    alert = %{id: :cpu_alert, sliding_window: [window_ms: 30_000, max_events: 3]}
    :ets.insert(@table, {{{:sliding_window, :cpu_alert}, 20_000}, 2})
    :ets.insert(@table, {{{:sliding_window, :cpu_alert}, 30_000}, 1})

    assert EventGuard.allow_sliding_window?(alert, 50_000)

    refute EventGuard.allow_sliding_window?(
             %{alert | sliding_window: [window_ms: 30_000, max_events: 4]},
             50_000
           )
  end

  test "record_sliding_window_event/2 increments the current sub-bucket" do
    alert = %{id: :cpu_alert}

    EventGuard.record_sliding_window_event(alert, 25_123)
    EventGuard.record_sliding_window_event(alert, 25_999)

    assert :ets.lookup(@table, {{:sliding_window, :cpu_alert}, 20_000}) == [
             {{{:sliding_window, :cpu_alert}, 20_000}, 2}
           ]
  end
end
