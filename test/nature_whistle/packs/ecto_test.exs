defmodule NatureWhistle.Packs.EctoTest do
  use ExUnit.Case, async: true

  alias NatureWhistle.Packs.Ecto

  defmodule Repo do
    def config do
      [
        otp_app: :my_app,
        telemetry_prefix: [:my_app, :repo]
      ]
    end
  end

  defmodule RepoWithoutTelemetryPrefix do
    def config do
      [otp_app: :my_app]
    end
  end

  test "returns all default Ecto alerts" do
    alerts = Ecto.alerts(repo: Repo)

    assert Enum.map(alerts, & &1.id) == [
             :nature_whistle_ecto_my_app_slow_query,
             :nature_whistle_ecto_my_app_slow_queue,
             :nature_whistle_ecto_my_app_slow_db_execution,
             :nature_whistle_ecto_my_app_slow_decode,
             :nature_whistle_ecto_my_app_slow_encode
           ]
  end

  test "uses the repo telemetry prefix for each alert" do
    alerts = Ecto.alerts(repo: Repo)

    assert Enum.all?(alerts, &(&1.event == [:my_app, :repo, :query]))
  end

  test "uses the default threshold for each metric" do
    alerts = Ecto.alerts(repo: Repo)

    assert Enum.map(alerts, & &1.threshold) == [
             1_000_000_000,
             100_000_000,
             500_000_000,
             100_000_000,
             100_000_000
           ]
  end

  test "configures the correct measurement for each alert" do
    alerts = Ecto.alerts(repo: Repo)

    assert Enum.map(alerts, & &1.measurement_key) == [
             :total_time,
             :queue_time,
             :query_time,
             :decode_time,
             :encode_time
           ]
  end

  test "uses a custom threshold for a metric" do
    alerts = Ecto.alerts(repo: Repo, thresholds: [slow_query: 250])

    [alert] = Enum.filter(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_query))

    assert alert.threshold == 250_000_000
  end

  test "allows multiple custom thresholds" do
    alerts =
      Ecto.alerts(
        repo: Repo,
        thresholds: [slow_query: 250, slow_queue: 75]
      )

    assert Enum.find(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_query)).threshold ==
             250_000_000

    assert Enum.find(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_queue)).threshold ==
             75_000_000

    assert Enum.find(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_db_execution)).threshold ==
             500_000_000
  end

  test "disables a metric when its threshold is false" do
    alerts = Ecto.alerts(repo: Repo, thresholds: [slow_query: false])

    refute Enum.any?(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_query))

    assert length(alerts) == 4
  end

  test "can disable multiple metrics" do
    alerts =
      Ecto.alerts(
        repo: Repo,
        thresholds: [slow_queue: false, slow_encode: false]
      )

    refute Enum.any?(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_queue))
    refute Enum.any?(alerts, &(&1.id == :nature_whistle_ecto_my_app_slow_encode))
    assert length(alerts) == 3
  end

  test "falls back to the default repo telemetry prefix" do
    alerts = Ecto.alerts(repo: RepoWithoutTelemetryPrefix)

    assert Enum.all?(alerts, &(&1.event == [:my_app, :repo, :query]))
  end

  test "uses the repo otp_app in alert ids" do
    alerts = Ecto.alerts(repo: Repo)

    assert Enum.map(alerts, & &1.id) == [
             :nature_whistle_ecto_my_app_slow_query,
             :nature_whistle_ecto_my_app_slow_queue,
             :nature_whistle_ecto_my_app_slow_db_execution,
             :nature_whistle_ecto_my_app_slow_decode,
             :nature_whistle_ecto_my_app_slow_encode
           ]
  end
end
