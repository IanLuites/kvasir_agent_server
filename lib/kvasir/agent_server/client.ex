defmodule Kvasir.AgentServer.Client do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.Client`.
  """
  use DynamicSupervisor
  import Kvasir.AgentServer, only: [default_control_port: 0]
  require Logger

  @transport :gen_tcp
  @pool_size 15

  @typep socket :: port
  @typep buffer :: [String.t()]
  @typep conn :: {socket, buffer}

  @opts ~w(pool_size async)a

  @doc @moduledoc
  @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    module = opts[:module] || raise "Need to set client module."

    {host, port, id, pool_size} =
      cond do
        url = opts[:url] ->
          case URI.parse(url) do
            %URI{scheme: "kvasir", host: host, port: port, path: "/" <> id, query: query} ->
              {host, port || default_control_port(), id,
               query
               |> Kernel.||("")
               |> URI.decode_query()
               |> Map.get("pool_size", @pool_size)}

            _ ->
              raise "Invalid Kvasir URI, expecting: `kvasir://<host>[:<port>]/<id>`."
          end

        opts[:host] && opts[:id] ->
          {opts[:host], opts[:port] || default_control_port(), opts[:host], @pool_size}

        :missing ->
          raise "Need to set Kvasir AgentServer `url`; or `host` and `id`."
      end

    o = opts |> Keyword.take(@opts) |> Keyword.put_new(:pool_size, pool_size)

    %{
      id: :kvasir_agent_server_client,
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [module, id, host, port, o]}
    }
  end

  @spec start_link(
          module,
          String.t(),
          String.t() | charlist,
          String.t() | pos_integer(),
          Keyword.t()
        ) :: {:ok, pid}
  def start_link(module, id, host, port, opts \\ []) do
    h = if(is_binary(host), do: String.to_charlist(host), else: host)
    p = if(is_binary(port), do: String.to_integer(port), else: port)

    o =
      opts
      |> Keyword.take(@opts)
      |> Keyword.update(
        :pool_size,
        @pool_size,
        &if(is_binary(&1), do: String.to_integer(&1), else: &1)
      )

    if Keyword.get(opts, :async, false) do
      DynamicSupervisor.start_link(__MODULE__, {nil, module, id, h, p, o}, name: module)
    else
      case DynamicSupervisor.start_link(__MODULE__, {self(), module, id, h, p, o}, name: module) do
        {:ok, pid} ->
          receive do
            :done_generating_agents -> {:ok, pid}
          end

        {:error, {a, b}} ->
          reraise a, b
      end
    end
  end

  @impl DynamicSupervisor
  def init({parent, module, id, host, port, opts}) do
    if Keyword.get(opts, :async, false) do
      spawn_link(fn -> initialize(nil, module, id, host, port, opts) end)
      DynamicSupervisor.init(strategy: :one_for_one)
    else
      initialize(parent, module, id, host, port, opts)
      DynamicSupervisor.init(strategy: :one_for_one)
    end
  end

  @spec initialize(
          parent :: pid | nil,
          module,
          String.t(),
          charlist,
          pos_integer(),
          Keyword.t()
        ) :: no_return
  def initialize(parent, module, id, host, port, opts) do
    # Create Conn Pool
    pool_size = Keyword.get(opts, :pool_size, @pool_size)

    # Connect
    conn = try_connect(host, port)

    # Wait till ready, then fetch and connect agents
    {:ok, conn} = wait_for_status(conn, "ready")
    {agents, conn} = connect(conn, id)

    if parent do
      spawn_link(fn ->
        connect_agents(module, agents, pool_size)
        send(parent, :done_generating_agents)
        control_loop(conn)
      end)
    else
      connect_agents(module, agents, pool_size)
      control_loop(conn)
    end
  end

  @spec try_connect(charlist, pos_integer, pos_integer) :: conn | no_return()
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

    case result do
      {:ok, conn} ->
        conn

      {:error, err} ->
        if attempt > 5,
          do:
            raise(
              "AgentServer Client failed to connect to: #{host}:#{port} after #{attempt} attempts."
            )

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

  defp connect_agents(module, agents, pool_size) do
    agents
    |> Enum.with_index()
    |> Enum.each(fn {%{host: h, port: p}, i} ->
      pool = :"#{module}.Pool#{i}"
      :ets.new(pool, [:named_table, :public, :set, read_concurrency: true])

      Enum.each(1..pool_size, fn pool_i ->
        {:ok, pid} =
          DynamicSupervisor.start_child(module, %{
            id: {i, pool_i},
            start:
              {Kvasir.AgentServer.Command.Connection, :start_link, [{pool, pool_i - 1}, h, p]}
          })

        conn = GenServer.call(pid, :get_conn)

        :ets.insert(pool, {pool_i - 1, conn})
      end)
    end)

    generate_client(module, agents, pool_size)
  end

  defp generate_client(module, agents, pool_size) do
    Code.compiler_options(ignore_module_conflict: true)

    if match?([_], agents) do
      pool = :"#{module}.Pool0"

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Kvasir.Command.Dispatcher

            def do_dispatch(cmd) do
              Kvasir.AgentServer.Command.Connection.send_command(get_conn(), cmd)
            end

            defp get_conn do
              id = rem(:erlang.unique_integer([:positive]), unquote(pool_size))
              [{^id, conn}] = :ets.lookup(unquote(pool), id)
              conn
            end
          end
        end
      )
    else
      conns =
        agents
        |> Enum.with_index()
        |> Enum.reduce(nil, fn
          {%{partition: {p, guard}}, i}, acc ->
            pool = :"#{module}.Pool#{i}"

            quote do
              unquote(acc)

              defp get_conn(unquote(p)) when unquote(guard) do
                id = rem(:erlang.unique_integer([:positive]), unquote(pool_size))
                [{^id, conn}] = :ets.lookup(unquote(pool), id)
                conn
              end
            end

          {%{partition: p}, i}, acc ->
            pool = :"#{module}.Pool#{i}"

            quote do
              unquote(acc)

              defp get_conn(unquote(p)) do
                id = rem(:erlang.unique_integer([:positive]), unquote(pool_size))
                [{^id, conn}] = :ets.lookup(unquote(pool), id)
                conn
              end
            end
        end)

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Kvasir.Command.Dispatcher

            def do_dispatch(cmd = %{__meta__: %{scope: {:instance, key}}}) do
              Kvasir.AgentServer.Command.Connection.send_command(get_conn(key), cmd)
            end

            unquote(conns)
          end
        end
      )
    end

    Code.compiler_options(ignore_module_conflict: false)
  end

  ### Wait For A Given Status
  @spec wait_for_status(conn, String.t()) :: {:ok, conn}
  defp wait_for_status(conn, status) do
    _send(conn, "STATUS")
    do_wait(conn, "STATUS #{status}")
  end

  @spec do_wait(conn, String.t()) :: {:ok, conn}
  defp do_wait(conn, line) do
    case read_line(conn) do
      {^line, conn} -> {:ok, conn}
      {_, conn} -> do_wait(conn, line)
    end
  end

  ### Connect ###

  @spec connect(conn, String.t()) :: {[map], conn}
  defp connect(conn, id) do
    send_raw(conn, ["CONNECT ", id, ?\n])

    {"LIST " <> _, conn} = read_line(conn)
    do_connect(conn)
  end

  @spec do_connect(conn, [map]) :: {[map], conn}
  defp do_connect(conn, acc \\ []) do
    case read_line(conn) do
      {"DONE " <> _, conn} ->
        {:lists.reverse(acc), conn}

      {line, conn} ->
        [id, target, port, partition] = String.split(line, " ", parts: 4)

        agent = %{
          id: id,
          host: target,
          port: String.to_integer(port),
          partition: parse_partition(partition)
        }

        do_connect(conn, [agent | acc])
    end
  end

  @spec parse_partition(String.t()) :: term
  defp parse_partition(partition)
  defp parse_partition("*"), do: {:_, [], Elixir}

  defp parse_partition(partition) do
    [match, compare, value] = String.split(partition, " ")

    {parse_partition_match(match),
     {parse_operator(compare), [context: Elixir, import: Kernel],
      [{:x, [], Elixir}, parse_value(value)]}}
  end

  defp parse_partition_match("."), do: {:x, [], Elixir}

  defp parse_partition_match(pattern) do
    pattern
    |> String.split(".", trim: true)
    |> :lists.reverse()
    |> Enum.reduce({:x, [], Elixir}, fn k, acc -> {:%{}, [], [{String.to_atom(k), acc}]} end)
  end

  defp parse_operator("="), do: :==
  defp parse_operator("<"), do: :<
  defp parse_operator("<="), do: :<=
  defp parse_operator(">"), do: :>
  defp parse_operator(">="), do: :>=

  defp parse_value(":" <> atom), do: String.to_atom(atom)
  defp parse_value("\"" <> string), do: String.slice(string, 0..-2)
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false
  defp parse_value(value), do: String.to_integer(value)

  ### Primitives ###

  @spec _send(conn, binary | iolist) :: :ok
  defp _send({socket, _}, data), do: @transport.send(socket, [data, ?\n])

  @spec send_raw(conn, binary | iolist) :: :ok
  defp send_raw({socket, _}, data), do: @transport.send(socket, data)

  @spec control_loop(conn) :: no_return
  defp control_loop(conn) do
    receive do
      :hold_it -> control_loop(conn)
    end
  end

  @spec read_line(conn) :: {String.t(), conn}
  defp read_line(conn)
  defp read_line({socket, [line | buffer]}), do: {line, {socket, buffer}}

  defp read_line({socket, []}) do
    {:ok, data} = @transport.recv(socket, 0, :infinity)
    read_line({socket, String.split(data, ~r/\r?\n/, trim: true)})
  end
end
