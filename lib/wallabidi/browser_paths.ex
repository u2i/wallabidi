defmodule Wallabidi.BrowserPaths do
  @moduledoc """
  Finds browser binaries — either a local binary to launch or a remote
  URL to connect to.

  ## Chrome resolution order

  1. `WALLABIDI_CHROME_URL` — connect to remote Chrome (`chrome:9222` or full `ws://` URL)
  2. `WALLABIDI_CHROME_PATH` — local Chrome binary to launch
  3. `.browsers/PATHS` file (written by `mix wallabidi.install`)
  4. System PATH

  ## Lightpanda resolution order

  1. `WALLABIDI_LIGHTPANDA_PATH` — local Lightpanda binary to launch
  2. `.browsers/PATHS` file (written by `mix wallabidi.install`)

  Lightpanda has no remote-URL mode here: the `lightpanda` package
  manages the binary and spawns it locally. When neither source
  resolves, the `lightpanda` package falls back to its own
  `Lightpanda.bin_path/0` (the version-stamped `.browsers/lightpanda/`
  dir, or `_build/`).

  ## Setup

      mix wallabidi.install

  Or for Docker/CI:

      WALLABIDI_CHROME_URL=chrome:9222 mix test.chrome
      WALLABIDI_LIGHTPANDA_PATH=/opt/lightpanda/lightpanda mix test.lightpanda
  """

  @paths_file ".browsers/PATHS"

  @doc """
  Returns `{:url, url}` for remote, `{:path, path}` for local, or `:error`.
  """
  def chrome do
    with :skip <- from_url("WALLABIDI_CHROME_URL"),
         :skip <- from_path("WALLABIDI_CHROME_PATH"),
         :skip <- from_paths_file("CHROME"),
         :skip <- from_system(["google-chrome", "chromium", "chromium-browser"]) do
      :error
    end
  end

  @doc "Returns the local Chrome binary path or raises."
  def chrome_path! do
    case chrome() do
      {:path, path} ->
        path

      {:url, _} ->
        raise "WALLABIDI_CHROME_URL is set — use chrome_url/0 instead of chrome_path!/0"

      :error ->
        raise "Chrome not found. Run `mix wallabidi.install` or set WALLABIDI_CHROME_PATH."
    end
  end

  @doc "Returns the remote Chrome URL or nil."
  def chrome_url do
    case chrome() do
      {:url, url} -> url
      _ -> nil
    end
  end

  @doc "Returns `{:ok, path}` for local Chrome, or `:error`. Ignores URLs."
  def chrome_path do
    case chrome() do
      {:path, path} -> {:ok, path}
      _ -> :error
    end
  end

  @doc """
  Returns `{:path, path}` for a resolved Lightpanda binary, or `:error`.

  Unlike `chrome/0` there is no remote-URL mode — the `lightpanda`
  package launches the binary locally.
  """
  def lightpanda do
    with :skip <- from_path("WALLABIDI_LIGHTPANDA_PATH"),
         :skip <- from_paths_file("LIGHTPANDA") do
      :error
    end
  end

  @doc "Returns `{:ok, path}` for a resolved Lightpanda binary, or `:error`."
  def lightpanda_path do
    case lightpanda() do
      {:path, path} -> {:ok, path}
      _ -> :error
    end
  end

  @doc """
  Returns the directory Lightpanda should install into, version-stamped
  to mirror Chrome for Testing's `.browsers/chrome/<target>-<version>/`
  layout — e.g. `.browsers/lightpanda/aarch64-macos-fork-2026-05-30`.

  Used both by `mix wallabidi.install` (to place the binary) and by the
  test config (to point `config :lightpanda, :install_dir` at the same
  spot so the runtime resolves it). Returns `nil` if the `lightpanda`
  package is unavailable or too old to expose `target/0` + `release/0`.
  """
  @lightpanda_install_root Path.join(".browsers", "lightpanda")
  def lightpanda_install_dir do
    if Code.ensure_loaded?(Lightpanda) and
         function_exported?(Lightpanda, :target, 0) and
         function_exported?(Lightpanda, :release, 0) do
      Path.join(@lightpanda_install_root, "#{Lightpanda.target()}-#{Lightpanda.release()}")
    end
  end

  # --- Private ---

  defp from_url(var) do
    case System.get_env(var) do
      nil -> :skip
      "" -> :skip
      url -> {:url, url}
    end
  end

  defp from_path(var) do
    case System.get_env(var) do
      nil -> :skip
      "" -> :skip
      path -> if File.exists?(path), do: {:path, path}, else: :skip
    end
  end

  defp from_paths_file(key) do
    case read_paths_file() do
      %{^key => path} when path != "" ->
        if File.exists?(path), do: {:path, path}, else: :skip

      _ ->
        :skip
    end
  end

  defp from_system(names) do
    Enum.find_value(names, :skip, fn name ->
      case System.find_executable(name) do
        nil -> nil
        path -> {:path, path}
      end
    end)
  end

  defp read_paths_file do
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
end
