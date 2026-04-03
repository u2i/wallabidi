defmodule Wallabidi.Mixfile do
  use Mix.Project

  @source_url "https://github.com/u2i/wallabidi"
  @version "0.1.43"
  @maintainers ["Tom Clarke"]

  def project do
    [
      app: :wallabidi,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      description:
        "Concurrent browser testing for Elixir, powered by WebDriver BiDi. A fork of Wallaby.",
      deps: deps(),
      docs: docs(),

      # Custom testing
      aliases: [
        "test.all": [
          "test",
          "test.live_view",
          "test.lightpanda",
          "test.chrome",
          "test.chrome.lifecycle"
        ],
        "test.live_view": &test_live_view/1,
        "test.lightpanda": &test_lightpanda/1,
        "test.chrome": &test_chrome/1,
        "test.chrome.lifecycle": &test_chrome_lifecycle/1
      ],
      test_paths: test_paths(System.get_env("WALLABIDI_DRIVER")),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.all": :test,
        "test.browsers": :test,
        "test.live_view": :test,
        "test.lightpanda": :test,
        "test.chrome": :test,
        "test.chrome.lifecycle": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Wallabidi, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "integration_test/support"]
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
      {:ecto_sql, "~> 3.12", optional: true},
      {:phoenix_ecto, "~> 4.6", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:lazy_html, "~> 0.1"},
      {:sandbox_shim, "~> 0.1"},
      # Test-only deps
      {:lightpanda, "0.2.8-3", only: :test},
      {:sandbox_case, "~> 0.3.8", only: :test},
      {:cachex, "~> 4.1", only: :test},
      {:fun_with_flags, "~> 1.11", only: :test, runtime: false},
      {:ecto_sqlite3, "~> 0.22", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:mimic, "~> 1.7", only: :test},
      {:mox, "~> 1.2", only: :test}
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
      main: "readme"
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:inets, :phoenix_ecto, :ecto_sql],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: false
    ]
  end

  defp test_paths("live_view"), do: ["integration_test/live_view"]
  defp test_paths("lightpanda"), do: ["integration_test/lightpanda"]
  defp test_paths("chrome"), do: ["integration_test/chrome"]
  defp test_paths("chrome_lifecycle"), do: ["integration_test/lifecycle/chrome"]
  defp test_paths(_), do: ["test"]

  defp test_live_view(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running LiveView driver integration tests")

    {_, res} =
      System.cmd("mix", ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [{"WALLABIDI_DRIVER", "live_view"}]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp test_lightpanda(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running Lightpanda CDP integration tests")

    {_, res} =
      System.cmd("mix", ["test", "--no-start" | args],
        into: IO.binstream(:stdio, :line),
        env: [{"WALLABIDI_DRIVER", "lightpanda"}]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp test_chrome(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running tests for WALLABIDI_DRIVER=chrome mix test")

    {_, res} =
      System.cmd("mix", ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [{"WALLABIDI_DRIVER", "chrome"}]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp test_chrome_lifecycle(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running lifecycle tests for chrome (subprocess)")

    {_, res} =
      System.cmd("mix", ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [
          {"WALLABIDI_DRIVER", "chrome_lifecycle"},
          {"WALLABIDI_NO_DOCKER", "1"}
        ]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end
