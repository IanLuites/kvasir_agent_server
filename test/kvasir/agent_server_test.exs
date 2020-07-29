defmodule Kvasir.AgentServerTest do
  use ExUnit.Case
  doctest Kvasir.AgentServer

  test "greets the world" do
    assert Kvasir.AgentServer.hello() == :world
  end
end
