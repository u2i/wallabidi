defmodule Mix.Tasks.Wallabidi.Install do
  @moduledoc """
  Installs Chrome for Testing and chromedriver.

  Uses `npx @puppeteer/browsers install` to download matched versions of
  Chrome and chromedriver into `.browsers/`. Writes the executable paths
  to `.browsers/PATHS` so `Wallabidi.BrowserPaths` can find them.

  ## Usage

      mix wallabidi.install              # latest stable
      mix wallabidi.install 147.0.7727   # specific version

  ## Requirements

  Requires `npx` (Node.js) to be installed. The downloaded binaries are
  cached — subsequent runs are fast.
  """
  use Mix.Task

  @install_dir ".browsers"
  @paths_file Path.join(@install_dir, "PATHS")

  @shortdoc "Install Chrome for Testing + chromedriver"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"

    ensure_npx!()
    File.mkdir_p!(@install_dir)

    Mix.shell().info("Installing Chrome for Testing @ #{version}...")
    chrome_path = install_browser("chrome", version)

    Mix.shell().info("Installing chromedriver @ #{version}...")
    chromedriver_path = install_browser("chromedriver", version)

    write_paths(chrome_path, chromedriver_path)

    Mix.shell().info("")
    Mix.shell().info("Installed:")
    Mix.shell().info("  Chrome:      #{chrome_path}")
    Mix.shell().info("  Chromedriver: #{chromedriver_path}")
    Mix.shell().info("")
    Mix.shell().info("Paths written to #{@paths_file}")
  end

  defp install_browser(browser, version) do
    {output, 0} =
      System.cmd(
        "npx",
        [
          "@puppeteer/browsers",
          "install",
          "#{browser}@#{version}",
          "--path",
          @install_dir,
          "--format",
          "{{path}}"
        ],
        stderr_to_stdout: true
      )

    path =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.trim()

    abs_path = Path.expand(path)

    unless File.exists?(abs_path) do
      Mix.raise(
        "Installation reported path #{abs_path} but file does not exist.\nOutput: #{output}"
      )
    end

    abs_path
  end

  defp write_paths(chrome, chromedriver) do
    content = "CHROME=#{chrome}\nCHROMEDRIVER=#{chromedriver}\n"
    File.write!(@paths_file, content)
  end

  defp ensure_npx! do
    unless System.find_executable("npx") do
      Mix.raise("""
      `npx` not found. Install Node.js to use `mix wallabidi.install`.

      Alternatively, set the paths manually:
        WALLABIDI_CHROME_PATH=/path/to/chrome
        WALLABIDI_CHROMEDRIVER_PATH=/path/to/chromedriver
      """)
    end
  end
end
