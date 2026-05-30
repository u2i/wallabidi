defmodule Wallabidi.Installer do
  @moduledoc false

  # Shared implementation behind the `mix wallabidi.install[.*]` tasks.
  #
  # Downloads browser binaries into a single project-local `.browsers/`
  # dir and records their resolved paths in `.browsers/PATHS` so
  # `Wallabidi.BrowserPaths` (and the test config) can find them.
  #
  # Each browser writes its own line in PATHS; installs merge into the
  # existing file rather than clobbering it, so `install.chrome` and
  # `install.lightpanda` can run independently without wiping each
  # other's entry.

  alias Wallabidi.BrowserPaths

  @install_dir ".browsers"
  @paths_file Path.join(@install_dir, "PATHS")

  @doc "The `.browsers` install dir."
  def install_dir, do: @install_dir

  @doc "The `.browsers/PATHS` manifest file."
  def paths_file, do: @paths_file

  @doc """
  Installs Chrome for Testing into `.browsers/`, records `CHROME=` in
  PATHS, and installs the chromium-bidi server's Node deps.

  `version` is a Chrome for Testing version string (e.g. `"147.0.7727"`)
  or `"stable"`.
  """
  def install_chrome(version \\ "stable") do
    load_app!()
    ensure_npx!()
    ensure_npm!()
    File.mkdir_p!(@install_dir)

    Mix.shell().info("Installing Chrome for Testing @ #{version}...")
    chrome_path = install_browser("chrome", version)
    merge_paths(%{"CHROME" => chrome_path})

    Mix.shell().info("Installing chromium-bidi server Node deps...")
    install_bidi_server_deps()

    Mix.shell().info("Installed Chrome: #{chrome_path}")
    Mix.shell().info("Paths written to #{@paths_file}")
    chrome_path
  end

  @doc """
  Installs the Lightpanda binary into a version-stamped
  `.browsers/lightpanda/<target>-<release>/` dir (mirroring Chrome's
  layout so releases coexist) and records `LIGHTPANDA=` in PATHS.

  Returns the resolved binary path, or `nil` if the `lightpanda` dep is
  unavailable or too old to support the `:install_dir` knob (in which
  case Lightpanda still works via the package's own `_build/` default —
  it's just not unified into `.browsers/`).
  """
  def install_lightpanda do
    load_app!()
    File.mkdir_p!(@install_dir)

    path = do_install_lightpanda()

    if path do
      merge_paths(%{"LIGHTPANDA" => path})
      Mix.shell().info("Installed Lightpanda: #{path}")
      Mix.shell().info("Paths written to #{@paths_file}")
    end

    path
  end

  @doc "Installs every browser (Chrome + chromium-bidi deps, then Lightpanda)."
  def install_all(version \\ "stable") do
    chrome_path = install_chrome(version)
    lightpanda_path = install_lightpanda()

    Mix.shell().info("")
    Mix.shell().info("Installed:")
    Mix.shell().info("  Chrome:     #{chrome_path}")
    if lightpanda_path, do: Mix.shell().info("  Lightpanda: #{lightpanda_path}")

    {chrome_path, lightpanda_path}
  end

  # --- Lightpanda ---

  defp do_install_lightpanda do
    cond do
      not Code.ensure_loaded?(Lightpanda) ->
        Mix.shell().info("Skipping Lightpanda (the `lightpanda` dep is not available).")
        nil

      not supports_install_dir?() ->
        Mix.shell().info("""
        Skipping Lightpanda install into #{@install_dir}/ — the `lightpanda`
        dependency predates the `:install_dir` knob. Lightpanda will still
        install into `_build/` via `mix lightpanda.install`. Upgrade the
        `lightpanda` dep to unify its location under #{@install_dir}/.
        """)

        nil

      true ->
        Mix.shell().info("Installing Lightpanda (#{Lightpanda.release()})...")
        # Redirect where the package installs the binary. The dir is
        # version-stamped (`.browsers/lightpanda/<target>-<release>`) to
        # mirror Chrome's `.browsers/chrome/<target>-<version>/` layout,
        # so releases coexist. We record the resulting absolute binary
        # path in `.browsers/PATHS` (the `LIGHTPANDA=` line); the test
        # config and the driver read it back from there at runtime.
        #
        # Clear any pre-set `:path` (config may have read an earlier
        # LIGHTPANDA= line from PATHS) so `:install_dir` — not the stale
        # path — governs where Lightpanda.install/0 writes and where
        # bin_path/0 then reports.
        prev_path = Application.get_env(:lightpanda, :path)
        prev_dir = Application.get_env(:lightpanda, :install_dir)

        try do
          Application.delete_env(:lightpanda, :path)
          Application.put_env(:lightpanda, :install_dir, BrowserPaths.lightpanda_install_dir())
          Lightpanda.install()
          path = Path.expand(Lightpanda.bin_path())
          fixup_macos_signature(path)
          path
        after
          restore_env(:lightpanda, :path, prev_path)
          restore_env(:lightpanda, :install_dir, prev_dir)
        end
    end
  end

  # The downloaded Lightpanda binary ships with a linker-signed ad-hoc
  # signature and a `com.apple.provenance` xattr. On macOS, launching it
  # non-interactively (under a BEAM Port) can get it SIGKILL'd (exit 137)
  # by Gatekeeper on first run. Stripping the xattrs and re-applying an
  # ad-hoc signature locally clears the assessment. No-op off Darwin, and
  # best-effort — if `codesign`/`xattr` are missing we leave the binary
  # as-is rather than fail the install.
  defp fixup_macos_signature(path) do
    if match?({:unix, :darwin}, :os.type()) do
      run_quietly("xattr", ["-c", path])
      run_quietly("codesign", ["--force", "--sign", "-", path])
    end

    :ok
  end

  defp run_quietly(cmd, args) do
    if exe = System.find_executable(cmd) do
      _ = System.cmd(exe, args, stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  # The `:install_dir` knob (and version-stamped layout) is only present
  # in newer `lightpanda` releases. Probe by checking whether setting it
  # actually moves bin_path/0 off the `_build/` default.
  #
  # `:path` outranks `:install_dir` in Lightpanda.bin_path/0, so we must
  # clear it during the probe — otherwise an already-configured `:path`
  # (e.g. from a prior install recorded in .browsers/PATHS) masks the
  # knob and the probe reports a false negative.
  defp supports_install_dir? do
    sentinel =
      Path.join(System.tmp_dir!(), "wallabidi-lp-probe-#{System.unique_integer([:positive])}")

    prev_dir = Application.get_env(:lightpanda, :install_dir)
    prev_path = Application.get_env(:lightpanda, :path)

    try do
      Application.delete_env(:lightpanda, :path)
      Application.put_env(:lightpanda, :install_dir, sentinel)
      String.starts_with?(Path.expand(Lightpanda.bin_path()), Path.expand(sentinel))
    after
      restore_env(:lightpanda, :install_dir, prev_dir)
      restore_env(:lightpanda, :path, prev_path)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # --- Chrome / chromium-bidi ---

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

  # --- PATHS manifest ---

  # Merges the given key/value entries into `.browsers/PATHS`, preserving
  # any existing lines for other browsers. Entries are written in a
  # stable order so the file diffs cleanly.
  defp merge_paths(updates) do
    merged = Map.merge(read_paths(), updates)

    content =
      ["CHROME", "LIGHTPANDA"]
      |> Enum.map(fn key -> {key, merged[key]} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("", fn {key, value} -> "#{key}=#{value}\n" end)

    File.write!(@paths_file, content)
  end

  defp read_paths do
    case File.read(@paths_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  # --- Prerequisites ---

  # Application.app_dir/2 (used to find priv/bidi-server when wallabidi
  # is loaded as a dep) requires the app to be loaded. Mix usually does
  # this, but when an install task is the first thing invoked in a
  # consumer project we may need to force it.
  defp load_app!, do: Application.load(:wallabidi)

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
