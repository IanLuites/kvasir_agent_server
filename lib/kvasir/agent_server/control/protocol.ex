defmodule Kvasir.AgentServer.Control.Protocol do
  def start_link(ref, transport, config) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, config])}
  end

  def init(ref, transport, {server, protocol}) do
    # Apply to not warn for client only
    {:ok, socket} = apply(:ranch, :handshake, [ref])
    transport.send(socket, ["HELLO ", to_string(System.system_time(:second)), ?\n])

    protocol.init(socket, transport, server)

    loop(socket, transport, server, protocol, [])
  end

  defp loop(socket, transport, server, protocol, buffer) do
    case transport.recv(socket, 0, :infinity) do
      {:ok, data} ->
        loop(
          socket,
          transport,
          server,
          protocol,
          process_data(socket, transport, server, protocol, data, buffer)
        )

      _err ->
        :ok = transport.close(socket)
        protocol.close(server)
    end
  end

  defp process_data(socket, transport, server, protocol, data, buffer) do
    case String.split(data, ~r/\r?\n/) do
      [b] -> [b | buffer]
      process -> handle_commands(socket, transport, server, protocol, process, buffer)
    end
  end

  defp handle_commands(socket, transport, server, protocol, received, []),
    do: handle_loop(socket, transport, server, protocol, received)

  defp handle_commands(socket, transport, server, protocol, [r | received], buffer) do
    b = :erlang.iolist_to_binary(:lists.reverse([r | buffer]))
    handle_commands(socket, transport, server, protocol, [b | received], [])
  end

  defp handle_loop(_socket, _transport, _server, _protocol, [""]), do: []
  defp handle_loop(_socket, _transport, _server, _protocol, [b]), do: [b]

  defp handle_loop(socket, transport, server, protocol, [cmd | received]) do
    case String.split(cmd, ~r/\s+/, trim: true) do
      [] -> :ok
      ["PING"] -> transport.send(socket, "PONG\n")
      c -> with {:reply, d} <- protocol.handle_command(c, server), do: transport.send(socket, d)
    end

    handle_loop(socket, transport, server, protocol, received)
  end
end
