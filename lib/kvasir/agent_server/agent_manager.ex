defmodule Kvasir.AgentServer.AgentManager do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.AgentManager`.
  """

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

  def start_link(opts \\ []) do
    children = Enum.map(opts[:agents], &agent_child_spec/1)

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def agent_child_spec(agent) do
    %{
      id: {agent.id, agent.partition},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [__MODULE__, agent.agent],
      start: {__MODULE__, :agent_start_link, [agent]}
    }
  end

  def agent_start_link(agent) do
    Supervisor.start_link(
      [
        {agent.agent, agent.opts},
        {Kvasir.AgentServer.Command.Handler, agent: agent}
      ],
      strategy: :rest_for_one
    )
  end
end
