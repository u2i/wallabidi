defmodule Wallabidi.Mixfile do
  use Mix.Project

  @source_url "https://github.com/u2i/wallabidi"
  @version "0.1.0"
  @maintainers ["Tom Clarke"]

  def project do
    [
      app: :wallabidi,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      description:
        "Concurrent browser testing for Elixir, powered by WebDriver BiDi. A fork of Wallaby.",
      deps: deps(),
      docs: docs(),

      # Custom testing
      aliases: ["test.all": ["test", "test.chrome"], "test.chrome": &test_chrome/1],
      test_paths: test_paths(System.get_env("WALLABY_DRIVER")),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.all": :test,
        "test.chrome": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Wallabidi, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  # need the testserver in dev for benchmarks to run
  defp elixirc_paths(:dev), do: ["lib", "integration_test/support/test_server.ex"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.1"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:bypass, "~> 1.0.0", only: :test},
      {:ex_doc, "~> 0.28", only: :dev},
      {:ecto_sql, ">= 3.0.0", optional: true},
      {:phoenix_ecto, ">= 3.0.0", optional: true}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "priv"],
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Wallaby (upstream)" => "https://github.com/elixir-wallaby/wallaby"
      }
    ]
  end

  defp docs do
    [
      extras: ["README.md": [title: "Introduction"]],
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "readme",
      logo: "guides/images/icon.png"
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:inets, :phoenix_ecto, :ecto_sql],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp test_paths("chrome"), do: ["integration_test/chrome"]
  defp test_paths(_), do: ["test"]

  defp test_chrome(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running tests for WALLABY_DRIVER=chrome mix test")

    {_, res} =
      System.cmd("mix", ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [{"WALLABY_DRIVER", "chrome"}]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end
