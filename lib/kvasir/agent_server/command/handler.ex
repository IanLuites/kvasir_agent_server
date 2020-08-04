defmodule Kvasir.AgentServer.Command.Handler do
  import Kvasir.AgentServer.Util, only: [recommended_listener_config: 1]

  @spec child_spec(Keyword.t()) :: :supervisor.child_spec()
  def child_spec(opts \\ []) do
    agent = opts[:agent] || raise "Command handlers need to be given a agent."
    port = opts[:port] || agent.opts[:port] || raise "Command handlers need to be given a port."
    id = opts[:id] || make_ref()
    config = recommended_listener_config(port: port)
    metrics = agent_metrics(agent, System.get_env("STATSD_URL"))

    # Apply to not warn for client only
    apply(:ranch, :child_spec, [
      id,
      :ranch_tcp,
      config,
      Kvasir.AgentServer.Command.Protocol,
      {agent, metrics}
    ])
  end

  @default_port 8125
  @supported_protocols ~W(statsd+udp statsd2+udp statsd statsd2 udp)

  @spec agent_metrics(map, String.t() | nil) :: fun | false
  defp agent_metrics(agent, url)
  defp agent_metrics(_agent, nil), do: false

  defp agent_metrics(agent, url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, port: p} when s in @supported_protocols ->
        pre_build_packet(agent, String.to_charlist(h), p || @default_port)

      _ ->
        raise "Invalid metrics url: #{inspect(url)}."
    end
  end

  ### UDP Building ###

  otp_release = :erlang.system_info(:otp_release)
  @addr_family if(otp_release >= '19', do: [1], else: [])

  defp pre_build_packet(agent, host, port) do
    {:ok, {ip1, ip2, ip3, ip4}} = :inet.getaddr(host, :inet)
    true = Code.ensure_loaded?(:gen_udp)

    anc_data_part =
      if function_exported?(:gen_udp, :send, 5) do
        [0, 0, 0, 0]
      else
        []
      end

    header =
      @addr_family ++
        [
          :erlang.band(:erlang.bsr(port, 8), 0xFF),
          :erlang.band(port, 0xFF),
          :erlang.band(ip1, 0xFF),
          :erlang.band(ip2, 0xFF),
          :erlang.band(ip3, 0xFF),
          :erlang.band(ip4, 0xFF)
        ] ++ anc_data_part

    p =
      if agent.partition == "*" do
        ""
      else
        m = agent.partition |> String.split(" ") |> List.last() |> String.trim("\"")
        "partition:#{m},"
      end

    fqdn =
      :net_adm.localhost()
      |> :net_adm.dns_hostname()
      |> elem(1)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    name = String.downcase(inspect(agent.agent))

    static =
      "kvasir.agent_server.commands:1|c|#host:#{fqdn},agent:#{name},topic:#{agent.id},#{p}command:"

    prefix = IO.iodata_to_binary([header, static])
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_udp.open(0, active: false)
      send(parent, {:socket, socket})
      :timer.sleep(:infinity)
    end)

    socket =
      receive do
        {:socket, s} -> s
      end

    fn %c{} -> Port.command(socket, prefix <> c.__command__(:type)) end
  end
end
