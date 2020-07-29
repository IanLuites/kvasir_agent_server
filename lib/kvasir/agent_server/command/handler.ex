defmodule Kvasir.AgentServer.Command.Handler do
  import Kvasir.AgentServer.Util, only: [recommended_listener_config: 1]

  @spec child_spec(Keyword.t()) :: :supervisor.child_spec()
  def child_spec(opts \\ []) do
    agent = opts[:agent] || raise "Command handlers need to be given a agent."
    port = opts[:port] || agent.opts[:port] || raise "Command handlers need to be given a port."
    id = opts[:id] || make_ref()
    config = recommended_listener_config(port: port)

    # Apply to not warn for client only
    apply(:ranch, :child_spec, [
      id,
      :ranch_tcp,
      config,
      Kvasir.AgentServer.Command.Protocol,
      agent
    ])
  end
end
