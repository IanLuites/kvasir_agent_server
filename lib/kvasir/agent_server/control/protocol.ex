defmodule Kvasir.AgentServer.Control.Protocol do
  # def start_link(ref, transport, opts) do
  #   {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}
  # end

  # def init({ref, transport, _opts}) do
  #   {:ok, socket} = :ranch.handshake(ref)
  #   :ok = transport.setopts(socket, [active: :once])
  #   :gen_statem.enter_loop(__MODULE__, [], :parse, )
  # end

  def start_link(ref, transport, server) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, server])}
  end

  def init(ref, transport, server) do
    # Apply to not warn for client only
    {:ok, socket} = apply(:ranch, :handshake, [ref])
    transport.send(socket, ["HELLO ", to_string(System.system_time(:second)), ?\n])
    loop(socket, transport, server, [])
  end

  defp loop(socket, transport, server, buffer) do
    case transport.recv(socket, 0, :infinity) do
      {:ok, data} ->
        loop(socket, transport, server, process_data(socket, transport, server, data, buffer))

      _err ->
        :ok = transport.close(socket)
    end
  end

  defp process_data(socket, transport, server, data, buffer) do
    case String.split(data, ~r/\r?\n/) do
      [b] -> [b | buffer]
      process -> handle_commands(socket, transport, server, process, buffer)
    end
  end

  defp handle_commands(socket, transport, server, received, []),
    do: handle_loop(socket, transport, server, received)

  defp handle_commands(socket, transport, server, [r | received], buffer) do
    b = :erlang.iolist_to_binary(:lists.reverse([r | buffer]))
    handle_commands(socket, transport, server, [b | received], [])
  end

  defp handle_loop(_socket, _transport, _server, [""]), do: []
  defp handle_loop(_socket, _transport, _server, [b]), do: [b]

  defp handle_loop(socket, transport, server, [cmd | received]) do
    case String.split(cmd, ~r/\s+/, trim: true) do
      [] -> :ok
      ["CONNECT" | opts] -> connect(socket, transport, server, opts)
      ["STATUS"] -> transport.send(socket, "STATUS ready\n")
      ["METRICS"] -> metrics(socket, transport, server)
      x -> IO.inspect(x, label: "CMD")
    end

    handle_loop(socket, transport, server, received)
  end

  ### The Commands
  alias Kvasir.AgentServer.Config

  defp connect(socket, transport, server, opts) do
    if id = List.first(opts) do
      a =
        server
        |> Config.agents(id)
        |> Enum.map(
          &[id, ?\ , ip!(&1.opts[:ip]), ?\ , to_string(&1.opts[:port]), ?\ , &1.partition, ?\n]
        )

      transport.send(socket, [
        ["LIST ", id, ?\n],
        a,
        ["DONE ", id, ?\n]
      ])
    else
      a =
        server
        |> Config.agents()
        |> Enum.map(
          &[&1.id, ?\ , ip!(&1.opts[:ip]), ?\ , to_string(&1.opts[:port]), ?\ , &1.partition, ?\n]
        )

      transport.send(socket, [
        ["LIST", ?\n],
        a,
        ["DONE", ?\n]
      ])
    end

    :ok
  end

  defp ip!(ip), do: :inet.ntoa(ip)

  defp metrics(socket, transport, server) do
    a =
      server
      |> Config.agents()
      |> Enum.map(&[&1.id, ?\ , &1.partition, ?\ , to_string(:counters.get(&1.counter, 1)), ?\n])

    transport.send(socket, [
      "METRICS\n",
      a,
      "DONE METRICS\n"
    ])

    :ok
  end
end
