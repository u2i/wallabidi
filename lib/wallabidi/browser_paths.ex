defmodule Wallabidi.BrowserPaths do
  @moduledoc """
  Finds Chrome — either a local binary to launch or a remote URL
  to connect to.

  ## Resolution order

  1. `WALLABIDI_CHROME_URL` — connect to remote Chrome (`chrome:9222` or full `ws://` URL)
  2. `WALLABIDI_CHROME_PATH` — local Chrome binary to launch
  3. `.browsers/PATHS` file (written by `mix wallabidi.install`)
  4. System PATH

  ## Setup

      mix wallabidi.install

  Or for Docker/CI:

      WALLABIDI_CHROME_URL=chrome:9222 mix test.chrome
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
