defmodule Kvasir.AgentServer.Client.ConnectionManager do
  @all Kvasir.AgentServer.Client
  @scope Kvasir.AgentServer.Client.Subscription
  @super Kvasir.AgentServer.Client.ConnectionManager
  @proto Kvasir.AgentServer.Client.Protocol

  @doc @moduledoc
  @spec start_link(opts :: Keyword.t()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    :ets.new(@all, [:named_table, :public, :set, read_concurrency: true])

    Supervisor.start_link(
      [
        %{
          id: @scope,
          start: {:pg, :start_link, [@scope]}
        },
        DynamicSupervisor.child_spec(strategy: :one_for_one, name: @super)
      ],
      strategy: :rest_for_one,
      name: @all
    )
  end

  def connect(host, port, client_pid) do
    h = if(is_binary(host), do: String.to_charlist(host), else: host)
    p = if(is_binary(port), do: String.to_integer(port), else: port)
    name = :"#{@super}.#{host}.#{port}"

    spec =
      Kvasir.AgentServer.Control.Connection.child_spec(
        host: h,
        port: p,
        name: name,
        protocol: @proto
      )

    if client_pid, do: :pg.join(@scope, name, client_pid)

    case DynamicSupervisor.start_child(@super, spec) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      err -> err
    end
  end

  @spec status(atom) :: atom
  defdelegate status(connection), to: Kvasir.AgentServer.Client.Protocol

  @spec agents(atom) :: %{required(String.t()) => list}
  defdelegate agents(connection), to: Kvasir.AgentServer.Client.Protocol

  @spec agents(atom, String.t()) :: list
  defdelegate agents(connection, id), to: Kvasir.AgentServer.Client.Protocol
end
