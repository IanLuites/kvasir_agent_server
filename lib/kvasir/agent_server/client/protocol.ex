defmodule Kvasir.AgentServer.Client.Protocol do
  @all Kvasir.AgentServer.Client
  @super Kvasir.AgentServer.Client.ConnectionManager
  @scope Kvasir.AgentServer.Client.Subscription

  def status(connection) do
    case :ets.lookup(@all, {connection, :status}) do
      [{_, s}] -> s
      _ -> :unknown
    end
  end

  def agents(connection) do
    case :ets.lookup(@all, {connection, :agents}) do
      [{_, agents}] -> agents
      _ -> %{}
    end
  end

  def agents(connection, id), do: connection |> agents() |> Map.get(id, [])

  def init(host, port) do
    id = :"#{@super}.#{host}.#{port}"

    :ets.insert(@all, {{id, :status}, :unknown})

    {:reply, "STATUS\nCONNECT",
     %{id: id, status: :unknown, mode: :connect, agents: %{}, buffer: nil}}
  end

  def close(state = %{agents: agents}) do
    s = %{state | status: :closed, agents: Map.new(agents, fn {k, _} -> {k, []} end)}

    notify_status(s)
    notify_agents(s, Map.keys(agents))

    :ok
  end

  def handle_line(line, state)

  def handle_line("STATUS " <> status, state = %{status: s}) do
    new = String.to_atom(status)

    if s != new do
      new_state = %{state | status: new}

      notify_status(new_state)

      {:ok, new_state}
    else
      :ok
    end
  end

  ### Connect All ###
  def handle_line("LIST", state = %{mode: :connect}),
    do: {:ok, %{state | mode: :connect_all, buffer: %{}}}

  def handle_line("DONE", state = %{mode: :connect_all, buffer: buffer}) do
    new_state = %{
      state
      | mode: nil,
        buffer: nil,
        agents: Map.new(buffer, fn {k, v} -> {k, :lists.reverse(v)} end)
    }

    notify_agents(new_state, Map.keys(buffer))

    {:ok, new_state}
  end

  def handle_line(line, state = %{mode: :connect_all, buffer: buffer}) do
    agent = parse_agent(line)
    {:ok, %{state | buffer: Map.update(buffer, agent.id, [agent], &[agent | &1])}}
  end

  ### Connect Specific ###
  def handle_line("LIST " <> id, state = %{mode: :connect}),
    do: {:ok, %{state | mode: :connect_specific, buffer: {id, []}}}

  def handle_line("DONE", state = %{mode: :connect_specific, buffer: {i, b}, agents: agents}) do
    new_state = %{
      state
      | mode: nil,
        buffer: nil,
        agents: Map.put(agents, i, :lists.reverse(b))
    }

    notify_agents(new_state, [i])

    {:ok, new_state}
  end

  def handle_line(line, state = %{mode: :connect_specific, buffer: {i, b}}) do
    {:ok, %{state | buffer: {i, [parse_agent(line) | b]}}}
  end

  ### Notify ###

  defp notify_status(%{id: id, status: s}) do
    :ets.insert(@all, {{id, :status}, s})
    msg = {id, :status, s}

    @scope
    |> :pg.get_members(id)
    |> Enum.each(fn listener ->
      send(listener, msg)
    end)
  end

  defp notify_agents(%{id: id, agents: agents}, updated_agents) do
    :ets.insert(@all, {{id, :agents}, agents})
    listeners = :pg.get_members(@scope, id)

    Enum.each(updated_agents, fn agent ->
      msg = {id, :agent, agent, agents[agent]}
      Enum.each(listeners, &send(&1, msg))
    end)
  end

  ### Agent Parsing ###

  @spec parse_agent(String.t()) :: map
  defp parse_agent(line) do
    [id, target, port, partition] = String.split(line, " ", parts: 4)

    %{
      id: id,
      host: target,
      port: String.to_integer(port),
      partition: parse_partition(partition)
    }
  end

  @spec parse_partition(String.t()) :: term
  defp parse_partition(partition)
  defp parse_partition("*"), do: {:_, [], Elixir}

  defp parse_partition(partition) do
    [match, compare, value] = String.split(partition, " ")

    {parse_partition_match(match),
     {parse_operator(compare), [context: Elixir, import: Kernel],
      [{:x, [], Elixir}, parse_value(value)]}}
  end

  defp parse_partition_match("."), do: {:x, [], Elixir}

  defp parse_partition_match(pattern) do
    pattern
    |> String.split(".", trim: true)
    |> :lists.reverse()
    |> Enum.reduce({:x, [], Elixir}, fn k, acc -> {:%{}, [], [{String.to_atom(k), acc}]} end)
  end

  defp parse_operator("="), do: :==
  defp parse_operator("<"), do: :<
  defp parse_operator("<="), do: :<=
  defp parse_operator(">"), do: :>
  defp parse_operator(">="), do: :>=

  defp parse_value(":" <> atom), do: String.to_atom(atom)
  defp parse_value("\"" <> string), do: String.slice(string, 0..-2)
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false
  defp parse_value(value), do: String.to_integer(value)
end
