defmodule Kvasir.AgentServer.Control.Server do
  def init(socket, transport, server) do
    # Join for status updates
    :pg.join({server, :status}, spawn_link(fn -> status_loop(socket, transport, server) end))

    :ok
  end

  def close(_server) do
    :ok
  end

  ### The Commands
  alias Kvasir.AgentServer.Config

  @spec handle_command([String.t()], term) :: :ok | {:reply, iodata()}
  def handle_command(command, server)

  def handle_command(["CONNECT" | opts], server) do
    if id = List.first(opts) do
      a =
        server
        |> Config.agents(id)
        |> Enum.map(
          &[id, ?\ , ip!(&1.opts[:ip]), ?\ , to_string(&1.opts[:port]), ?\ , &1.partition, ?\n]
        )

      {:reply,
       [
         ["LIST ", id, ?\n],
         a,
         ["DONE ", id, ?\n]
       ]}
    else
      a =
        server
        |> Config.agents()
        |> Enum.map(
          &[&1.id, ?\ , ip!(&1.opts[:ip]), ?\ , to_string(&1.opts[:port]), ?\ , &1.partition, ?\n]
        )

      {:reply,
       [
         ["LIST", ?\n],
         a,
         ["DONE", ?\n]
       ]}
    end
  end

  def handle_command(["METRICS"], server) do
    a =
      server
      |> Config.agents()
      |> Enum.map(&[&1.id, ?\ , &1.partition, ?\ , to_string(:counters.get(&1.counter, 1)), ?\n])

    {:reply,
     [
       "METRICS\n",
       a,
       "DONE METRICS\n"
     ]}
  end

  def handle_command(["STATUS"], server),
    do: {:reply, ["STATUS ", to_string(Config.status(server)), ?\n]}

  def handle_command(unknown, server) do
    require Logger

    Logger.warn(fn ->
      "Kvasir AgentServer<#{inspect(server)}>: Received unknown control command: #{
        inspect(unknown)
      } "
    end)

    :ok
  end

  defp ip!(ip), do: :inet.ntoa(ip)

  defp status_loop(socket, transport, server) do
    receive do
      {:status, ^server, new} -> transport.send(socket, ["STATUS ", to_string(new), ?\n])
    end

    status_loop(socket, transport, server)
  end
end
