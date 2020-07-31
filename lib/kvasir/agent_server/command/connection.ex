defmodule Kvasir.AgentServer.Command.Connection do
  require Logger
  @transport :gen_tcp
  @socket_opts [:binary, active: false]
  @linger_time 250

  def create(id, host, port, janitor) do
    {:ok, pid} = start_link(id, host, port, janitor)
    {:ok, GenServer.call(pid, :get_conn)}
  end

  def send_command(conn, command, latency)
  def send_command(err = {:error, _}, _cmd, _latency), do: err

  def send_command(conn, command = %{__meta__: m}, latency) do
    need_response = m.wait != :dispatch
    {registry, socket} = conn

    cmd = %{
      command
      | __meta__: m |> Map.from_struct() |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()
    }

    packed = :erlang.term_to_binary(cmd, minor_version: 2, compressed: 9)
    size = byte_size(packed)

    wait_time = m.timeout + latency

    if need_response do
      :ets.insert(
        registry,
        {m.id, self(), :erlang.system_time(:millisecond) + wait_time + @linger_time}
      )
    end

    with :ok <- @transport.send(socket, [<<size::unsigned-integer-32>>, packed]) do
      if need_response, do: wait_for_response(command, wait_time), else: :ok
    else
      {:error, :no_socket, _} -> {:error, :agent_server_connection_lost}
      err -> err
    end
  end

  defp wait_for_response(command, timeout) do
    receive do
      {:ok, meta} ->
        {:ok, %{command | __meta__: struct!(Kvasir.Command.Meta, meta)}}

      {_, {:ok, _, _}} ->
        wait_for_response(command, timeout)

      x = {_, err} ->
        if elem(err, 0) == :ok,
          do: Logger.error(fn -> "AgentServer: Weird Response: #{inspect(x)}" end)

        err
    after
      timeout -> {:error, :remote_command_timeout}
    end
  end

  def start_link(id, host, port, janitor) do
    GenServer.start_link(__MODULE__, {id, host, port, janitor})
  end

  @behaviour GenServer

  @impl GenServer
  def init({id, host, port, janitor}) do
    h = if(is_binary(host), do: String.to_charlist(host), else: host)

    {:ok, socket} = @transport.connect(h, port, @socket_opts)
    registry = :ets.new(:registry, [:set, :public, write_concurrency: true])
    send(janitor, {:add_table, registry})
    reader = spawn_link(fn -> response_loop(id, registry, h, port, socket) end)

    {:ok, %{id: id, socket: socket, registry: registry, reader: reader}}
  end

  defp response_loop(id, registry, host, port, socket) do
    case @transport.recv(socket, 4, :infinity) do
      {:ok, <<length::unsigned-integer-32>>} ->
        {:ok, data} = @transport.recv(socket, length, :infinity)
        response = :erlang.binary_to_term(data)

        ref =
          case response do
            {:ok, %{id: ref}} -> ref
            {ref, _} -> ref
          end

        with [{^ref, pid, _}] <- :ets.take(registry, ref), do: send(pid, response)

        response_loop(id, registry, host, port, socket)

      {:error, :closed} ->
        # Clear REF
        {pool, index} = id
        :ets.insert(pool, {index, {:error, :agent_server_connection_lost}})
        Logger.error(fn -> "AgentServer: Connection Lost" end)
        connect_loop(id, registry, host, port)
    end
  end

  defp connect_loop(id, registry, host, port, attempt \\ 1) do
    case @transport.connect(host, port, @socket_opts) do
      {:ok, socket} ->
        # Set REF
        {pool, index} = id
        :ets.insert(pool, {index, {registry, socket}})
        Logger.info(fn -> "AgentServer: Connection Reconnected" end)
        response_loop(id, registry, host, port, socket)

      _ ->
        :timer.sleep(attempt * 500)

        if attempt <= 5 do
          connect_loop(id, registry, host, port, attempt + 1)
        else
          raise "Connection lost."
        end
    end
  end

  @impl GenServer
  def handle_call(:get_conn, _from, state = %{registry: r, socket: s}) do
    {:reply, {r, s}, state}
  end
end
