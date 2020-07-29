defmodule Kvasir.AgentServer.Config do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.Config`.
  """

  @spec agents(Kvasir.AgentServer.id()) :: [Kvasir.AgentServer.agent()]
  def agents(server) do
    case :ets.lookup(server, :agents) do
      [{:agents, a}] -> a
      _ -> []
    end
  end

  @spec agents(Kvasir.AgentServer.id(), String.t()) :: [Kvasir.AgentServer.agent()]
  def agents(server, id), do: server |> agents() |> Enum.filter(&(&1.id == id))

  # use GenServer

  # @doc @moduledoc
  # @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  # def child_spec(opts \\ []) do
  #   server = Keyword.fetch!(opts, :server)
  #   agents = Keyword.fetch!(opts, :agents)

  #   %{
  #     id: :config,
  #     restart: :permanent,
  #     shutdown: :infinity,
  #     type: :worker,
  #     modules: [__MODULE__],
  #     start: {__MODULE__, :start_link, [server, agents]}
  #   }
  # end

  # @doc false
  # @spec start_link(server :: Kvasir.AgentServer.id(), agents :: [Kvasir.AgentServer.agent()]) ::
  #         Supervisor.on_start()
  # def start_link(server, agents) do
  #   GenServer.start_link(__MODULE__, {server, agents})
  # end

  # @impl GenServer
  # def init({server, agents}) do
  #   {:ok, %{server: server, agents: agents, state: :booting}}
  # end
end
