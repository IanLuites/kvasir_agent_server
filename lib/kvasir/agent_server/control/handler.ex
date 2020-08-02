defmodule Kvasir.AgentServer.Control.Handler do
  import Kvasir.AgentServer.Util, only: [recommended_listener_config: 1]

  @spec child_spec(Keyword.t()) :: :supervisor.child_spec()
  def child_spec(opts \\ []) do
    id = opts[:id] || make_ref()
    protocol = Keyword.get(opts, :protocol, Kvasir.AgentServer.Control.Server)
    config = recommended_listener_config(opts)

    # Apply to not warn for client only
    apply(:ranch, :child_spec, [
      id,
      :ranch_tcp,
      config,
      Kvasir.AgentServer.Control.Protocol,
      {opts[:server], protocol}
    ])
  end
end
