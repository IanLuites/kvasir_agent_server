defmodule Kvasir.AgentServer.Config do
  @moduledoc ~S"""
  Documentation for `Kvasir.AgentServer.Config`.
  """

  def child_spec(_opts \\ []) do
    %{id: :config, start: {:pg, :start_link, []}}
  end

  @spec status(Kvasir.AgentServer.id()) :: Kvasir.AgentServer.status()
  def status(server) do
    case :ets.lookup(server, :status) do
      [{:status, s}] -> s
      _ -> :unknown
    end
  end

  @spec set_status(Kvasir.AgentServer.id(), Kvasir.AgentServer.status()) :: :ok
  def set_status(server, status) do
    :ets.insert(server, {:status, status})

    {server, :status} |> :pg.get_members() |> Enum.each(&send(&1, {:status, server, status}))

    :ok
  end

  @spec agents(Kvasir.AgentServer.id()) :: [Kvasir.AgentServer.agent()]
  def agents(server) do
    case :ets.lookup(server, :agents) do
      [{:agents, a}] -> a
      _ -> []
    end
  end

  @spec agents(Kvasir.AgentServer.id(), String.t()) :: [Kvasir.AgentServer.agent()]
  def agents(server, id), do: server |> agents() |> Enum.filter(&(&1.id == id))

  @spec set_agents(Kvasir.AgentServer.id(), [Kvasir.AgentServer.agent()]) :: :ok
  def set_agents(server, agents) do
    :ets.insert(server, {:agents, agents})

    :ok
  end

  ### Connection ###

  import Kvasir.AgentServer, only: [default_control_port: 0]

  @pool_size 15
  @latency 1_000

  def connection(opts \\ []) do
    base = if(u = opts[:url], do: url(u), else: [])

    base
    |> Keyword.merge(Keyword.take(opts, ~w(id host port pool_size latency async)a))
    |> Keyword.update(
      :host,
      'localhost',
      &if(is_binary(&1), do: String.to_charlist(&1), else: &1)
    )
    |> Keyword.update(:port, default_control_port(), &integer!/1)
    |> Keyword.update(:latency, @pool_size, &integer!/1)
    |> Keyword.update(:latency, @latency, &integer!/1)
    |> Keyword.update(:async, false, &boolean!/1)
  end

  @spec url(binary | URI.t()) :: [
          {:host, charlist}
          | {:id, binary}
          | {:latency, pos_integer()}
          | {:pool_size, pos_integer}
          | {:port, :inet.port_number()}
          | {:async, boolean},
          ...
        ]
  def url(url) do
    case URI.parse(url) do
      %URI{scheme: "kvasir", host: host, port: port, path: "/" <> id, query: query} ->
        q = query |> Kernel.||("") |> URI.decode_query()

        [
          id: id,
          host: String.to_charlist(host),
          port: port || default_control_port(),
          latency: integer!(Map.get(q, "latency", @latency)),
          pool_size: integer!(Map.get(q, "pool_size", @pool_size)),
          async: boolean!(Map.get(q, "async", false))
        ]

      _ ->
        raise "Invalid Kvasir URI, expecting: `kvasir://<host>[:<port>]/<id>[?<options>]`."
    end
  end

  defp integer!(value)
  defp integer!(value) when is_integer(value), do: value
  defp integer!(value) when is_binary(value), do: String.to_integer(value)

  defp boolean!(value)
  defp boolean!(true), do: true
  defp boolean!(false), do: false
  defp boolean!(value) when is_integer(value), do: value > 0

  defp boolean!(value) when is_binary(value),
    do: String.downcase(value) in ["true", "1", "yes", "y"]

  defp boolean!(value), do: !!value
end
