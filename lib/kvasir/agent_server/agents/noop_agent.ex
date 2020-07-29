defmodule Kvasir.AgentServer.NOOPAgent.Source do
  @moduledoc false

  @doc false
  @spec __topics__() :: map
  def __topics__(),
    do: %{
      "noop" => %{
        key: Kvasir.Key.Integer,
        partitions: 100
      }
    }
end

defmodule Kvasir.AgentServer.NOOPAgent.Cache do
  @moduledoc false

  @doc false
  @spec init(any, any, any) :: :ok
  def init(_, _, _), do: :ok

  @doc false
  @spec load(any, any, any) :: {:ok, 0, nil}
  def load(_, _, _) do
    {:ok, 0, nil}
  end

  @doc false
  @spec track_command(any, any, any) :: {:ok, 0}
  def track_command(_, _, _) do
    {:ok, 0}
  end
end

defmodule Kvasir.AgentServer.NOOPAgent do
  @moduledoc ~S"""
  A NOOP agent.

  Executes the command, but never executes.
  """

  @doc ~S"""
  Create a customized NOOP agent.
  """
  def customized(name, opts \\ []) do
    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use Kvasir.Agent,
            registry: Kvasir.Agent.Registry.Local,
            source: unquote(opts[:source] || Kvasir.AgentServer.NOOPAgent.Source),
            cache: unquote(opts[:cache] || Kvasir.AgentServer.NOOPAgent.Cache),
            model: Kvasir.AgentServer.NOOPAgent,
            topic: unquote(opts[:topic] || "noop")
        end
      end
    )
  end

  use Kvasir.Agent,
    registry: Kvasir.Agent.Registry.Local,
    source: Kvasir.AgentServer.NOOPAgent.Source,
    cache: Kvasir.AgentServer.NOOPAgent.Cache,
    model: Kvasir.AgentServer.NOOPAgent,
    topic: "noop"

  @doc false
  @spec base(any) :: nil
  def base(_), do: nil

  @doc false
  @spec apply(any, any) :: :ok
  def apply(_, _), do: :ok

  @doc false
  @spec execute(any, any) :: :ok
  def execute(_, _), do: :ok
end
