defmodule NatureWhistleTest do
  use ExUnit.Case
  doctest NatureWhistle

  test "greets the world" do
    assert NatureWhistle.hello() == :world
  end
end
