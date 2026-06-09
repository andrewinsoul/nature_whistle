defmodule NatureWhistle.TestNotifier do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def deliver(message, _metadata, _config) do
    Agent.update(__MODULE__, &[message | &1])
    {:ok, :sent}
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  def get_messages do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end
end
