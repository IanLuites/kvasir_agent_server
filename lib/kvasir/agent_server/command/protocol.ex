defmodule Kvasir.AgentServer.Command.Protocol do
  require Logger
  @read_timeout 1_000

  def start_link(ref, transport, _agent = %{agent: agent, counter: counter}) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, agent, counter])}
  end

  def init(ref, transport, agent, counter) do
    # Apply to not warn for client only
    {:ok, socket} = apply(:ranch, :handshake, [ref])
    loop(socket, transport, agent, counter)
  end

  defp loop(socket, transport, agent, counter) do
    case transport.recv(socket, 4, :infinity) do
      {:ok, <<length::unsigned-integer-32>>} ->
        parent = self()

        spawn(fn -> grab_command(socket, transport, agent, parent, length) end)

        receive do
          :next_command -> :ok
        after
          @read_timeout -> :ok
        end

        :counters.add(counter, 1, 1)
        loop(socket, transport, agent, counter)

      {:error, :closed} ->
        transport.close(socket)

      err ->
        Logger.error(fn -> "AgentServer: Error parsing payload: #{inspect(err)}" end)
        :ok = transport.close(socket)
    end
  end

  defp grab_command(socket, transport, agent, parent, length) do
    with {:ok, data} <- transport.recv(socket, length, @read_timeout),
         send(parent, :next_command),
         {:ok, cmd} <- unpack(data) do
      dispatch(socket, transport, agent, cmd)
    else
      err ->
        Logger.error(fn -> "AgentServer: Error parsing command: #{inspect(err)}" end)
    end
  end

  defp dispatch(socket, transport, agent, command = %{__meta__: meta}) do
    if meta.wait == :dispatch do
      agent.dispatch(command)
    else
      case agent.dispatch(command) do
        {:ok, %{__meta__: m}} -> return_meta(socket, transport, m)
        err -> return_result(socket, transport, {meta.id, err})
      end
    end
  end

  defp return_meta(socket, transport, meta) do
    trimmed = meta |> Map.from_struct() |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()
    return_result(socket, transport, {:ok, trimmed})
  end

  defp return_result(socket, transport, result) do
    packed = :erlang.term_to_binary(result, minor_version: 2, compressed: 9)
    size = byte_size(packed)
    transport.send(socket, [<<size::unsigned-integer-32>>, packed])
  end

  @spec unpack(binary) :: {:ok, Kvasir.Command.t()} | {:error, atom}
  def unpack(command) do
    case :erlang.binary_to_term(command) do
      cmd = %{__meta__: m} -> {:ok, %{cmd | __meta__: struct!(Kvasir.Command.Meta, m)}}
      _ -> {:error, :invalid_command}
    end
  rescue
    ArgumentError -> {:error, :invalid_command_encoding}
  end
end
