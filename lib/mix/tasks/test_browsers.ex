defmodule Mix.Tasks.Test.Browsers do
  @shortdoc "Run integration tests on multiple browsers"
  @moduledoc """
  Runs the integration test suite once per listed browser.

  All tests run on each browser — including tests that would normally
  use the LiveView driver. This is for CI cross-browser coverage.

      mix test.browsers --browsers chrome
      mix test.browsers --browsers chrome,firefox

  Any additional arguments are forwarded to `mix test`:

      mix test.browsers --browsers chrome --only integration
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, remaining} = OptionParser.parse!(args, strict: [browsers: :string])

    browsers =
      opts
      |> Keyword.get(:browsers, "chrome")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    remaining =
      if IO.ANSI.enabled?(), do: ["--color" | remaining], else: ["--no-color" | remaining]

    Enum.each(browsers, &run_browser(&1, remaining))
  end

  defp run_browser(browser, args) do
    IO.puts("==> Running all tests on #{browser}")

    {_, res} =
      System.cmd("mix", ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [
          {"WALLABIDI_DRIVER", browser},
          {"WALLABIDI_BROWSER", browser}
        ]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end
end
