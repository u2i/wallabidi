defmodule Mix.Tasks.Wallabidi.Install do
  @moduledoc """
  Installs Chrome for Testing and the chromium-bidi server's Node deps.

  Uses `npx @puppeteer/browsers install` to download Chrome into
  `.browsers/`. Runs `npm install` in `priv/bidi-server/` to fetch the
  chromium-bidi Node package and its peer deps. Writes the executable
  path to `.browsers/PATHS` so `Wallabidi.BrowserPaths` can find it.

  ## Usage

      mix wallabidi.install              # latest stable
      mix wallabidi.install 147.0.7727   # specific version

  ## Requirements

  Requires `npx` and `npm` (Node.js) to be installed. The downloaded
  binaries and Node modules are cached — subsequent runs are fast.

  ChromeDriver is no longer installed; wallabidi's BiDi driver speaks
  directly to chromium-bidi.
  """
  use Mix.Task

  @install_dir ".browsers"
  @paths_file Path.join(@install_dir, "PATHS")

  @shortdoc "Install Chrome for Testing + chromium-bidi Node deps"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"

    ensure_npx!()
    ensure_npm!()
    File.mkdir_p!(@install_dir)

    Mix.shell().info("Installing Chrome for Testing @ #{version}...")
    chrome_path = install_browser("chrome", version)

    write_paths(chrome_path)

    Mix.shell().info("Installing chromium-bidi server Node deps...")
    install_bidi_server_deps()

    Mix.shell().info("")
    Mix.shell().info("Installed:")
    Mix.shell().info("  Chrome: #{chrome_path}")
    Mix.shell().info("")
    Mix.shell().info("Paths written to #{@paths_file}")
  end

  defp install_bidi_server_deps do
    bidi_dir = bidi_server_dir()

    if File.dir?(Path.join(bidi_dir, "node_modules")) and
         File.exists?(Path.join([bidi_dir, "node_modules", "chromium-bidi"])) do
      Mix.shell().info("  (cached — node_modules/ already present)")
    else
      {_, 0} =
        System.cmd("npm", ["install"],
          cd: bidi_dir,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )
    end
  end

  defp bidi_server_dir do
    Path.join(File.cwd!(), "priv/bidi-server")
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

  defp write_paths(chrome) do
    content = "CHROME=#{chrome}\n"
    File.write!(@paths_file, content)
  end

  defp ensure_npx! do
    unless System.find_executable("npx") do
      Mix.raise("""
      `npx` not found. Install Node.js to use `mix wallabidi.install`.

      Alternatively, set the path manually:
        WALLABIDI_CHROME_PATH=/path/to/chrome
      """)
    end
  end

  defp ensure_npm! do
    unless System.find_executable("npm") do
      Mix.raise("""
      `npm` not found. Install Node.js to use `mix wallabidi.install`.
      The chromium-bidi server runs as a small Node process.
      """)
    end
  end
end
