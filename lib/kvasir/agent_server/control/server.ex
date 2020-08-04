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

  def handle_command(["REBUILD", topic | opts], server) do
    [key | part] = :lists.reverse(opts)
    partition = part |> :lists.reverse() |> Enum.join(" ")

    if agent =
         Enum.find_value(
           Config.agents(server, topic),
           &if(&1.partition == partition, do: &1.agent)
         ) do
      with {:ok, p_key} <- agent.__agent__(:key).parse(key),
           true <- match_partition?(partition, p_key) || {:error, :key_partition_mismatch},
           :ok <- agent.rebuild(p_key) do
        {:reply, "OK\n"}
      else
        {:error, err} -> {:reply, "ERR #{inspect(err)}\n"}
      end
    else
      {:reply, "ERR unknown_agent\n"}
    end
  end

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

  ### Partition Matching ###
  @spec match_partition?(String.t(), term) :: boolean
  defp match_partition?(partition, key)
  defp match_partition?("*", _key), do: true

  defp match_partition?(partition, key) do
    [match, compare, value] = String.split(partition, " ")

    match = match_partition_match(match, key)
    value = match_partition_value(value)

    match_partition_compare(compare, match, value)
  end

  defp match_partition_match(".", key), do: key

  defp match_partition_match(pattern, key) do
    pattern
    |> String.split(".", trim: true)
    |> Enum.reduce(key, &MapX.get(&2, String.to_atom(&1)))
  end

  defp match_partition_compare("=", match, value), do: match == value
  defp match_partition_compare("<", match, value), do: match < value
  defp match_partition_compare("<=", match, value), do: match <= value
  defp match_partition_compare(">", match, value), do: match > value
  defp match_partition_compare(">=", match, value), do: match >= value

  defp match_partition_value(":" <> atom), do: String.to_atom(atom)
  defp match_partition_value("\"" <> string), do: String.slice(string, 0..-2)
  defp match_partition_value("true"), do: true
  defp match_partition_value("false"), do: false
  defp match_partition_value(value), do: String.to_integer(value)
end
