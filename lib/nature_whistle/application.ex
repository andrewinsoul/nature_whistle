defmodule NatureWhistle.Application do
  @moduledoc """
  Compatibility facade for NatureWhistle runtime setup functions.

  `NatureWhistle.Setup` owns initialization and runtime configuration, while
  `NatureWhistle.Supervisor` owns the supervised processes. Host applications
  should supervise `NatureWhistle.Supervisor` directly.
  """

  defdelegate load_config_into_ets(schedulers_online), to: NatureWhistle.Setup
  defdelegate register_alert(alert), to: NatureWhistle.Setup
  defdelegate unregister_alert(alert_id), to: NatureWhistle.Setup
  defdelegate refresh_beam_collector(), to: NatureWhistle.Setup, as: :sync_beam_collector
end
