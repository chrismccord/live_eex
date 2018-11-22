defmodule LiveEexTest do
  use ExUnit.Case
  doctest LiveEex

  test "greets the world" do
    assert LiveEex.hello() == :world
  end
end
