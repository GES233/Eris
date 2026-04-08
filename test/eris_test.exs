defmodule ErisTest do
  use ExUnit.Case
  doctest Eris

  test "greets the world" do
    assert Eris.hello() == :world
  end
end
