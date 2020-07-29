defmodule Kvasir.AgentServer do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer`.
  """

  @default_control_port 9393
  @default_agent_ports [
    9397,
    9399,
    9733,
    9737,
    9739,
    9773,
    9777,
    9779,
    9793,
    9797,
    9799,
    9933,
    9937,
    9939,
    9973,
    9977,
    9979,
    9993,
    9997,
    9999
  ]

  @doc """
  Default control port for Kvasir AgentServer.

  Commonly: `#{@default_control_port}`
  """
  @spec default_control_port :: pos_integer()
  def default_control_port, do: @default_control_port

  @doc """
  Default ports to use for agents command handlers.

  Commonly: #{@default_agent_ports |> Enum.map(&"\n- `#{&1}`") |> Enum.join()}
  """
  @spec default_agent_ports :: [pos_integer()]
  def default_agent_ports, do: @default_agent_ports

  @type id :: atom | reference()
  @type agent :: %{
          server: id,
          id: String.t(),
          agent: module,
          partition: String.t(),
          opts: Keyword.t()
        }

  use Supervisor

  @doc @moduledoc
  @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    server = opts[:id] || make_ref()
    agents = agents(opts[:agents])

    %{
      id: server,
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [server, agents]}
    }
  end

  @doc false
  @spec start_link(id :: id, agents :: [agent]) :: Supervisor.on_start()
  def start_link(id, agents)

  def start_link(id, agents) do
    ensure_ranch!()

    {:ok, ips} = :inet.getif()
    {ip, _, _} = List.first(ips)

    agents =
      agents
      |> Enum.zip(default_agent_ports())
      |> Enum.map(fn {agent, p} ->
        agent
        |> Map.put(:server, id)
        |> Map.update!(:opts, &(&1 |> Keyword.put_new(:ip, ip) |> Keyword.put_new(:port, p)))
      end)

    if is_atom(id) do
      Supervisor.start_link(__MODULE__, {id, agents}, name: id)
    else
      Supervisor.start_link(__MODULE__, {id, agents})
    end
  end

  @impl Supervisor
  def init({id, agents}) do
    :ets.new(id, [:named_table, :set, :protected, read_concurrency: true])

    :ets.insert(id, {:agents, agents})

    children = [
      # {__MODULE__.Config, server: id, agents: agents},
      {__MODULE__.Control.Handler, server: id},
      {__MODULE__.AgentManager, agents: agents}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec ensure_ranch! :: :ok | no_return()
  defp ensure_ranch! do
    case :application.start(:ranch) do
      :ok -> :ok
      {:error, {:already_started, :ranch}} -> :ok
    end
  end

  @spec agents(term) :: [agent] | no_return()
  defp agents(nil), do: raise("Missing `:agents` in child spec options.")

  defp agents(agent) when is_map(agent) do
    agent |> Enum.to_list() |> agents()
  end

  defp agents(agents), do: Enum.map(agents, &agent_entry/1)

  defp agent_entry({id, agent}),
    do: %{
      id: id,
      agent: agent,
      partition: "*",
      counter: :counters.new(1, [:write_concurrency]),
      opts: []
    }

  defp agent_entry({id, agent, opts}) do
    {partition, o} = Keyword.pop(opts, :partition)

    p = partition || "*"

    %{
      id: id,
      agent: agent,
      partition: p,
      counter: :counters.new(1, [:write_concurrency]),
      opts: o
    }
  end

  defp agent_entry(agent = %{}) do
    id = agent[:id] || agent["id"] || raise "Missing agent id: #{inspect(agent)}"

    agent =
      case agent[:agent] || agent["agent"] do
        a when is_atom(a) -> a
        a when is_binary(a) -> String.to_existing_atom(a)
        _ -> raise "Missing agent: #{inspect(agent)}"
      end

    partition = agent[:partition] || agent["partition"] || "*"

    opts =
      Enum.map(agent[:opts] || agent["opts"] || [], fn
        {k, v} when is_atom(k) -> {k, v}
        {k, v} -> {String.to_existing_atom(k), v}
      end)

    %{
      id: id,
      agent: agent,
      partition: partition,
      counter: :counters.new(1, [:write_concurrency]),
      opts: opts
    }
  end
end
