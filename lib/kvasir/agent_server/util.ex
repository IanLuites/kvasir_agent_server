defmodule Kvasir.AgentServer.Util do
  @moduledoc false
  alias Kvasir.AgentServer

  @doc ~S"""
  Parse port setting to integer.
  """
  @spec port!(any) :: pos_integer
  def port!(value)
  def port!(value) when is_integer(value), do: value
  def port!(value) when is_binary(value), do: String.to_integer(value)
  def port!(_), do: AgentServer.default_control_port()

  @doc ~S"""
  Lookup the recommended number of acceptors.
  """
  @spec recommended_num_accepters :: pos_integer()
  def recommended_num_accepters, do: System.schedulers()

  @doc ~S"""
  Lookup the recommended amount of acceptors.
  """
  @spec recommended_listener_config(Keyword.t()) :: map
  def recommended_listener_config(opts \\ []) do
    # https://stressgrid.com/blog/100k_cps_with_elixir/
    num_listen_sockets = num_conns_sups = num_acceptors = recommended_num_accepters()

    %{
      max_connections: 6000,
      num_listen_sockets: num_listen_sockets,
      num_conns_sups: num_conns_sups,
      num_acceptors: num_acceptors,
      socket_opts: [so_reuseport!(), port: port!(opts[:port]), keepalive: true]
    }
  end

  @doc ~S"""
  Generate SO_REUSEPORT flag for unix systems.
  """
  @spec so_reuseport! :: {:raw, integer, integer, binary} | no_return()
  def so_reuseport! do
    case :os.type() do
      {:unix, :linux} -> {:raw, 1, 15, <<1::32-native>>}
      {:unix, :darwin} -> {:raw, 0xFFFF, 0x0200, <<1::32-native>>}
    end
  end
end
