defmodule Kvasir.AgentServer.Control.Connection do
  require Logger

  @transport :gen_tcp
  @opts ~w(async name protocol)a
  @heartbeat_interval 60_000

  @typep socket :: port
  @typep buffer :: [String.t()]
  @type t :: {socket, buffer}

  def child_spec(opts \\ []) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    h = if(is_binary(host), do: String.to_charlist(host), else: host)
    p = if(is_binary(port), do: String.to_integer(port), else: port)
    o = Keyword.take(opts, @opts)

    %{
      id: {h, p},
      restart: :permanent,
      shutdown: :infinity,
      type: :worker,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [h, p, o]}
    }
  end

  def start_link(host, port, opts \\ []) do
    h = if(is_binary(host), do: String.to_charlist(host), else: host)
    p = if(is_binary(port), do: String.to_integer(port), else: port)
    protocol = Keyword.fetch!(opts, :protocol)

    with {:ok, conn} <- try_connect(h, p) do
      {:ok, spawn_link(__MODULE__, :run, [host, port, conn, protocol])}
    end
  end

  @spec run(charlist(), pos_integer, t, module) :: no_return
  def run(host, port, conn, protocol) do
    host |> protocol.init(port) |> handle_protocol(conn, nil) |> do_run(conn, protocol)
  end

  defp do_run(state, conn, protocol) do
    case read_line(conn) do
      :closed ->
        protocol.close(state)

      {line, c} ->
        line
        |> protocol.handle_line(state)
        |> handle_protocol(c, state)
        |> do_run(c, protocol)
    end
  end

  defp handle_protocol(response, conn, state)
  defp handle_protocol(:ok, _conn, state), do: state
  defp handle_protocol({:ok, s}, _conn, _state), do: s

  defp handle_protocol({:reply, d}, conn, state) do
    write_line(conn, d)
    state
  end

  defp handle_protocol({:reply, d, s}, conn, _state) do
    write_line(conn, d)
    s
  end

  @spec try_connect(charlist, pos_integer, pos_integer) :: {:ok, t} | {:error, atom}
  defp try_connect(host, port, attempt \\ 1) do
    socket_opts = [:binary, active: false]

    result =
      case @transport.connect(host, port, socket_opts) do
        {:ok, socket} ->
          case read_line({socket, []}) do
            {"HELLO " <> _, conn} -> {:ok, conn}
            err -> {:error, err}
          end

        err ->
          {:error, err}
      end

    with {:error, err} <- result do
      if attempt > 5 do
        Logger.error(fn ->
          "AgentServer Client failed to connect to: #{host}:#{port} after #{attempt} attempts."
        end)

        {:error, :failed_to_connect}
      else
        timeout = attempt * 500

        Logger.error(fn ->
          "AgentServer Client failed to connect to: #{host}:#{port} (attempt ##{attempt}), retrying in #{
            timeout
          }ms. (Reason: #{inspect(err)})"
        end)

        :timer.sleep(timeout)

        try_connect(host, port, attempt + 1)
      end
    end
  end

  @spec write(t | socket, iodata()) :: :ok | {:error, atom}
  def write(conn, data)
  def write({socket, _}, data), do: @transport.send(socket, data)
  def write(socket, data), do: @transport.send(socket, data)

  @spec write_line(t | socket, iodata()) :: :ok | {:error, atom}
  def write_line(conn, data), do: write(conn, [data, ?\n])

  @spec read_line(t, boolean) :: {String.t(), t} | :closed
  defp read_line(conn, flagged \\ false)
  defp read_line({socket, ["PONG" | buffer]}, _flagged), do: read_line({socket, buffer}, false)
  defp read_line({socket, [line | buffer]}, _flagged), do: {line, {socket, buffer}}

  defp read_line({socket, []}, flagged) do
    case @transport.recv(socket, 0, @heartbeat_interval) do
      {:ok, data} ->
        read_line({socket, String.split(data, ~r/\r?\n/, trim: true)}, flagged)

      {:error, _} ->
        if flagged do
          @transport.close(socket)
          :closed
        else
          write(socket, "PING\n")
          read_line({socket, []}, true)
        end
    end
  end
end
