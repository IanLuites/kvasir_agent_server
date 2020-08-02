defmodule Kvasir.AgentServer.AgentManager do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.AgentManager`.
  """
  alias Kvasir.AgentServer.Config
  require Logger

  @doc @moduledoc
  @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: :manager,
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    server = opts[:server]
    warmup = opts[:warmup] || false

    Config.set_status(server, :starting)
    children = Enum.map(opts[:agents], &agent_child_spec(&1, warmup, self()))

    with {:ok, started} <- Supervisor.start_link(children, strategy: :one_for_one) do
      children |> Enum.map(& &1.id) |> wait_for_children()

      Config.set_status(server, :ready)

      {:ok, started}
    end
  end

  @spec wait_for_children([term]) :: :ok | no_return()
  defp wait_for_children(children)
  defp wait_for_children([]), do: :ok

  defp wait_for_children(children) do
    receive do
      {:agent_socket_ready, id} -> children |> Enum.reject(&(&1 == id)) |> wait_for_children
    end
  end

  @spec agent_child_spec(
          %{agent: module, id: any, partition: String.t()},
          boolean,
          pid
        ) :: %{
          id: {any, String.t()},
          modules: [module],
          restart: :permanent,
          shutdown: :infinity,
          start: {DynamicSupervisor, :start_link, [term]},
          type: :supervisor
        }
  def agent_child_spec(agent, warmup, parent) do
    %{
      id: {agent.id, agent.partition},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [DynamicSupervisor, __MODULE__, agent.agent],
      start:
        {DynamicSupervisor, :start_link,
         [__MODULE__, [agent: agent, parent: parent, warmup: warmup]]}
    }
  end

  @behaviour DynamicSupervisor
  @impl DynamicSupervisor
  @spec init(Keyword.t()) :: {:ok, DynamicSupervisor.sup_flags()} | :ignore
  def init(opts) do
    supervisor = self()
    agent = Keyword.fetch!(opts, :agent)
    server = agent.server
    parent = Keyword.fetch!(opts, :parent)
    warmup = Keyword.fetch!(opts, :warmup)

    spawn_link(fn ->
      [
        {agent.agent, Keyword.put(agent.opts, :generate_command_registry, false)},
        {Kvasir.AgentServer.Command.Handler, agent: agent}
      ]
      |> Enum.each(&DynamicSupervisor.start_child(supervisor, &1))

      send(parent, {:agent_socket_ready, {agent.id, agent.partition}})

      if warmup do
        Logger.info(
          "Kvasir AgentServer<#{inspect(server)}>: Warming up #{inspect(agent.agent)} agents..."
        )

        warmed_up = agent.agent.warmup()

        Logger.info(
          "Kvasir AgentServer<#{inspect(server)}>: Warmed up #{warmed_up} #{inspect(agent.agent)} agents."
        )
      end
    end)

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
