defmodule NatureWhistle.Supervisor do
  @moduledoc """
  Top-level supervisor for the NatureWhistle runtime.

  Add `NatureWhistle.Supervisor` to the host application's supervision tree
  when the host should own NatureWhistle's lifecycle and restart policy.
  """

  use Supervisor

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = NatureWhistle.Application.child_specs()
    Supervisor.init(children, strategy: :one_for_one)
  end
end
