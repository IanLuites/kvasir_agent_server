defmodule Kvasir.AgentServer.MixProject do
  use Mix.Project
  @version "0.0.1"

  def project do
    [
      app: :kvasir_agent_server,
      description: "AgentServer for Kvasir agents.",
      version: @version,
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),

      # Testing
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      # dialyzer: [ignore_warnings: "dialyzer.ignore-warnings", plt_add_deps: true],

      # Docs
      name: "Kvasir AgentServer",
      source_url: "https://github.com/IanLuites/kvasir_agent_server",
      homepage_url: "https://github.com/IanLuites/kvasir_agent_server",
      docs: [
        main: "readme",
        extras: ["README.md"],
        source_url: "https://github.com/IanLuites/kvasir_agent_server"
      ]
    ]
  end

  def package do
    [
      name: :kvasir_agent_server,
      maintainers: ["Ian Luites"],
      licenses: ["MIT"],
      files: [
        # Elixir
        "lib/agent_server",
        "lib/agent_server.ex",
        ".formatter.exs",
        "mix.exs",
        "README*",
        "LICENSE*"
      ],
      links: %{
        "GitHub" => "https://github.com/IanLuites/kvasir_agent_server"
      }
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:kvasir_agent, ">= 0.0.1"},
      {:ranch, "~> 2.0", optional: true}
    ]
  end
end
