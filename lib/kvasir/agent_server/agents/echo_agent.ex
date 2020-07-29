defmodule Kvasir.AgentServer.EchoAgent do
  @moduledoc ~S"""
  An Echo agent.
  """
  use Kvasir.Command.Dispatcher

  @doc false
  @impl Kvasir.Command.Dispatcher
  def do_dispatch(cmd = %{__meta__: meta}) do
    n = UTCDateTime.utc_now()

    m =
      case meta.wait do
        :dispatch -> %{meta | dispatched: n}
        :execute -> %{meta | dispatched: n, executed: n}
        :apply -> %{meta | dispatched: n, executed: n, applied: n}
      end

    {:ok, %{cmd | __meta__: m}}
  end

  ### Fake Agent ###

  @doc false
  @spec child_spec(Keyword.t()) :: map
  def child_spec(_opts \\ []), do: %{id: :echo, start: {Agent, :start_link, [fn -> 0 end]}}

  @doc false
  @spec dispatch!(Kvasir.Command.t(), Keyword.t()) :: Kvasir.Command.t() | no_return
  def dispatch!(command, opts \\ []) do
    case dispatch(command, opts) do
      {:ok, cmd} -> cmd
      {:error, err} -> raise "Command dispatch failed: #{inspect(err)}."
    end
  end

  @doc false
  @spec open(any) :: {:ok, pid} | {:error, atom}
  def open(_id), do: {:error, :mock_agent}

  # @doc false
  # @spec inspect(any) :: {:ok, term} | {:error, atom}
  # def inspect(_id), do: {:error, :mock_agent}

  @doc false
  @spec count :: non_neg_integer
  def count, do: 0

  @doc false
  @spec list :: [term]
  def list, do: []

  @doc false
  @spec whereis(any) :: pid | nil
  def whereis(_id), do: nil

  @doc false
  @spec alive?(any) :: boolean
  def alive?(_id), do: false

  @doc false
  @spec sleep(id :: any, reason :: atom) :: :ok
  def sleep(_id, _reason \\ :sleep), do: :ok

  @doc false
  @spec config(component :: atom, opts :: Keyword.t()) :: Keyword.t()
  def config(_component, opts), do: opts

  defoverridable config: 2

  @doc false
  @spec __agent__(atom) :: term
  def __agent__(:config),
    do: %{
      agent: __MODULE__,
      cache: false,
      source: false,
      model: false,
      registry: false,
      topic: false,
      key: false
    }

  def __agent__(:topic), do: false
  def __agent__(:key), do: false
end
