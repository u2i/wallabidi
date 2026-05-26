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
  """
  use Mix.Task

  @install_dir ".browsers"
  @paths_file Path.join(@install_dir, "PATHS")

  @shortdoc "Install Chrome for Testing + chromium-bidi Node deps"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"

    # Application.app_dir/2 (used to find priv/bidi-server when
    # wallabidi is loaded as a dep) requires the app to be loaded.
    # Mix usually does this, but when this task is the first thing
    # invoked in a consumer project we may need to force it.
    _ = Application.load(:wallabidi)

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

    cond do
      not File.dir?(bidi_dir) ->
        Mix.raise("""
        Could not find chromium-bidi server dir at #{bidi_dir}.

        This usually means `wallabidi` was loaded but its package files
        weren't unpacked, or the task is being run from outside a Mix
        project. Try `mix deps.get && mix deps.compile wallabidi` first.
        """)

      File.dir?(Path.join(bidi_dir, "node_modules")) and
          File.exists?(Path.join([bidi_dir, "node_modules", "chromium-bidi"])) ->
        Mix.shell().info("  (cached — node_modules/ already present)")

      true ->
        case System.cmd("npm", ["install"],
               cd: bidi_dir,
               stderr_to_stdout: true,
               into: IO.stream(:stdio, :line)
             ) do
          {_, 0} ->
            :ok

          {_, status} ->
            Mix.raise("npm install in #{bidi_dir} failed with exit status #{status}")
        end
    end
  end

  # The chromium-bidi server lives in wallabidi's `priv/bidi-server/`
  # — when wallabidi is a dependency we have to resolve through
  # Application.app_dir/2, not the consumer's File.cwd!. Falls back to
  # cwd-relative for in-tree development (where Mix.Project is wallabidi
  # itself).
  defp bidi_server_dir do
    case Application.app_dir(:wallabidi, "priv/bidi-server") do
      path when is_binary(path) ->
        if File.dir?(path), do: path, else: cwd_bidi_server_dir()

      _ ->
        cwd_bidi_server_dir()
    end
  rescue
    ArgumentError -> cwd_bidi_server_dir()
  end

  defp cwd_bidi_server_dir, do: Path.join(File.cwd!(), "priv/bidi-server")

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
