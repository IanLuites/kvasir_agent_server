defmodule Kvasir.AgentServer.Command.Janitor do
  @moduledoc ~S"""
  Janitor for response tables, cleans out left over responses.
  """
  use GenServer

  @interval 60_000
  @opts ~w(interval tables)a

  @doc @moduledoc
  @spec child_spec(opts :: Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    o = Keyword.take(opts, @opts)

    %{
      id: :cleaner,
      restart: :permanent,
      shutdown: :infinity,
      type: :worker,
      modules: [__MODULE__],
      start: {__MODULE__, :start_link, [o]}
    }
  end

  @doc false
  @spec start_link(Keyword.t()) :: {:ok, pid}
  def start_link(opts \\ []) do
    o = Keyword.take(opts, @opts)
    GenServer.start_link(__MODULE__, o)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    tables = Keyword.get(opts, :tables, [])

    Process.send_after(self(), :janitor_duty, interval)

    {:ok, %{tables: tables, interval: interval}}
  end

  @impl GenServer
  def handle_info(:janitor_duty, state = %{tables: tables, interval: interval}) do
    t =
      if tables != [] do
        # Generate matcher
        time = :erlang.system_time(:millisecond)
        match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", time}], [true]}]

        # Cleanup
        cleanup_tables(tables, match_spec)
      else
        tables
      end

    # Queue next
    Process.send_after(self(), :janitor_duty, interval)

    {:noreply, %{state | tables: t}}
  end

  def handle_info({:add_table, table}, state = %{tables: tables}) do
    if table in tables do
      {:noreply, state}
    else
      {:noreply, %{state | tables: [table | tables]}}
    end
  end

  def handle_info({:remove_table, table}, state = %{tables: tables}) do
    {:noreply, %{state | tables: Enum.reject(tables, &(&1 == table))}}
  end

  @spec cleanup_tables([:ets.tab()], :ets.match_spec(), [:ets.tab()], non_neg_integer()) :: [
          :ets.tab()
        ]
  defp cleanup_tables(tables, match_spec, acc \\ [], cleaned \\ 0)

  defp cleanup_tables([], _match_spec, acc, cleaned) do
    if cleaned > 0 do
      require Logger
      Logger.info(fn -> "KvasirClient: Cleaned #{cleaned} responses from command table." end)
    end

    acc
  end

  defp cleanup_tables([table | tables], match_spec, acc, cleaned) do
    c = :ets.select_delete(table, match_spec)
    cleanup_tables(tables, match_spec, [table | acc], cleaned + c)
  rescue
    _ -> cleanup_tables(tables, match_spec, acc, cleaned)
  end
end
