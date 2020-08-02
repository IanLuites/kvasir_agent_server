defmodule Kvasir.AgentServer.Application do
  @moduledoc false
  use Application

  @doc false
  @spec start(any, any) :: {:error, term} | {:ok, pid()} | {:ok, pid(), term}
  def start(_type, _args), do: Kvasir.AgentServer.Client.ConnectionManager.start_link()
end
