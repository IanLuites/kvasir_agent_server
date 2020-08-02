defmodule Kvasir.AgentServer.Client do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.Client`.
  """
  use DynamicSupervisor
  alias Kvasir.AgentServer.Client.ConnectionManager
  alias Kvasir.AgentServer.Config
  require Logger

  @pool_size 15
  @latency 1_000

  @typep conn :: atom

  @opts ~w(pool_size async latency)a

  @doc @moduledoc
  @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    module = opts[:module] || raise "Need to set client module."
    {connect, o} = Keyword.split(Config.connection(opts), ~w(id host port)a)

    %{
      id: :kvasir_agent_server_client,
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [module, connect[:id], connect[:host], connect[:port], o]}
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
    o = Keyword.take(Config.connection(opts), @opts)

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
    spawn_link(fn -> initialize(parent, module, id, host, port, opts) end)
    DynamicSupervisor.init(strategy: :one_for_one)
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
    latency = Keyword.get(opts, :latency, @latency)

    # Connect
    {:ok, conn} = ConnectionManager.connect(host, port, self())
    wait_for_ready!(conn)

    # Wait till ready, then fetch and connect agents
    agents = wait_for_agents!(conn, id)
    {:ok, janitor} = DynamicSupervisor.start_child(module, Kvasir.AgentServer.Command.Janitor)

    connect_agents(module, agents, janitor, pool_size, latency)
    parent && send(parent, :done_generating_agents)
    control_loop(conn, module, id, agents, janitor, pool_size, latency)
  end

  # @spec control_loop(conn) :: no_return
  defp control_loop(conn, module, id, agents, janitor, pool_size, latency) do
    receive do
      {^conn, :agent, ^id, ags} ->
        regenerate_agents(module, agents, ags, janitor, pool_size, latency)
        control_loop(conn, module, id, ags, janitor, pool_size, latency)

      {^conn, :agent, _, _} ->
        control_loop(conn, module, id, agents, janitor, pool_size, latency)

      {^conn, :status, :closed} ->
        regenerate_agents(module, agents, [], janitor, pool_size, latency)
        control_loop(conn, module, id, [], janitor, pool_size, latency)

      {^conn, :status, :ready} ->
        ags = ConnectionManager.agents(conn, id)
        regenerate_agents(module, agents, ags, janitor, pool_size, latency)
        control_loop(conn, module, id, ags, janitor, pool_size, latency)

      _ ->
        # Add some checks here
        control_loop(conn, module, id, agents, janitor, pool_size, latency)
    end
  end

  @spec wait_for_ready!(conn) :: :ok
  defp wait_for_ready!(conn) do
    unless ConnectionManager.status(conn) == :ready, do: do_wait_for_ready!(conn)

    :ok
  end

  defp do_wait_for_ready!(conn) do
    receive do
      {^conn, :status, :ready} ->
        :ok

      _ ->
        # Add some checks here
        do_wait_for_ready!(conn)
    end
  end

  defp wait_for_agents!(conn, id) do
    with [] <- ConnectionManager.agents(conn, id), do: do_wait_for_agents!(conn, id)
  end

  defp do_wait_for_agents!(conn, id) do
    receive do
      {^conn, :agent, ^id, agents} ->
        agents

      _ ->
        # Add some checks here
        do_wait_for_agents!(conn, id)
    end
  end

  defp regenerate_agents(module, old_agents, new_agents, janitor, pool_size, latency)
  defp regenerate_agents(_, agents, agents, _, _, _), do: :ok

  defp regenerate_agents(module, old_agents, new_agents, janitor, pool_size, latency) do
    # Close old connections
    if old_agents != [] do
      module
      |> DynamicSupervisor.which_children()
      |> Enum.filter(&(elem(&1, 3) == [Kvasir.AgentServer.Command.Connection]))
      |> Enum.each(&DynamicSupervisor.terminate_child(module, elem(&1, 1)))
    end

    # Connect new
    connect_agents(module, new_agents, janitor, pool_size, latency)
  end

  defp connect_agents(module, agents, janitor, pool_size, latency)

  defp connect_agents(module, [], _janitor, pool_size, latency),
    do: generate_client(module, [], pool_size, latency)

  defp connect_agents(module, agents, janitor, pool_size, latency) do
    agents
    |> Enum.with_index()
    |> Enum.each(fn {%{host: h, port: p}, i} ->
      pool = :"#{module}.Pool#{i}"

      if :ets.info(pool) == :undefined,
        do: :ets.new(pool, [:named_table, :public, :set, read_concurrency: true])

      Enum.each(1..pool_size, fn pool_i ->
        {:ok, pid} =
          DynamicSupervisor.start_child(module, %{
            id: {i, pool_i},
            start:
              {Kvasir.AgentServer.Command.Connection, :start_link,
               [{pool, pool_i - 1}, h, p, janitor]}
          })

        conn = GenServer.call(pid, :get_conn)

        :ets.insert(pool, {pool_i - 1, conn})
      end)
    end)

    generate_client(module, agents, pool_size, latency)
  end

  defp generate_client(module, [], _pool_size, _latency) do
    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Kvasir.Command.Dispatcher

          def do_dispatch(_cmd), do: {:error, :agent_server_connection_lost}
        end
      end,
      Path.join(__DIR__, "BufferConn.ex")
    )

    Code.compiler_options(ignore_module_conflict: false)
  end

  defp generate_client(module, agents, pool_size, latency) do
    Code.compiler_options(ignore_module_conflict: true)

    if match?([_], agents) do
      pool = :"#{module}.Pool0"

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Kvasir.Command.Dispatcher

            def do_dispatch(cmd) do
              Kvasir.AgentServer.Command.Connection.send_command(
                get_conn(),
                cmd,
                unquote(latency)
              )
            end

            defp get_conn do
              id = rem(:erlang.unique_integer([:positive]), unquote(pool_size))
              [{^id, conn}] = :ets.lookup(unquote(pool), id)
              conn
            end
          end
        end,
        Path.join(__DIR__, "SingleConn.ex")
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
              Kvasir.AgentServer.Command.Connection.send_command(
                get_conn(key),
                cmd,
                unquote(latency)
              )
            end

            unquote(conns)
          end
        end,
        Path.join(__DIR__, "MultiConn.ex")
      )
    end

    Code.compiler_options(ignore_module_conflict: false)
  end
end
