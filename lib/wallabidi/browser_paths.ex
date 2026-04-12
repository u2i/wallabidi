defmodule Wallabidi.BrowserPaths do
  @moduledoc """
  Finds Chrome and chromedriver — either local binaries to launch or
  remote URLs to connect to.

  ## Resolution order

  ### Chrome (CDP driver)
  1. `WALLABIDI_CHROME_URL` — connect to remote Chrome DevTools (`ws://...`)
  2. `WALLABIDI_CHROME_PATH` — local Chrome binary to launch
  3. `.browsers/PATHS` file (written by `mix wallabidi.install`)
  4. System PATH

  ### Chromedriver (BiDi driver)
  1. `WALLABIDI_CHROMEDRIVER_URL` — connect to remote chromedriver (`http://...`)
  2. `WALLABIDI_CHROMEDRIVER_PATH` — local chromedriver binary to launch
  3. `.browsers/PATHS` file
  4. System PATH

  ## Setup

      mix wallabidi.install

  Or for Docker/CI:

      WALLABIDI_CHROME_URL=ws://chrome:9222/devtools/browser/... mix test.chrome
      WALLABIDI_CHROMEDRIVER_URL=http://chromedriver:9515/ mix test.chrome.bidi
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

  @doc """
  Returns `{:url, url}` for remote, `{:path, path}` for local, or `:error`.
  """
  def chromedriver do
    with :skip <- from_url("WALLABIDI_CHROMEDRIVER_URL"),
         :skip <- from_path("WALLABIDI_CHROMEDRIVER_PATH"),
         :skip <- from_paths_file("CHROMEDRIVER"),
         :skip <- from_system(["chromedriver"]) do
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

  @doc "Returns the local chromedriver binary path or raises."
  def chromedriver_path! do
    case chromedriver() do
      {:path, path} ->
        path

      {:url, _} ->
        raise "WALLABIDI_CHROMEDRIVER_URL is set — use chromedriver_url/0 instead"

      :error ->
        raise "Chromedriver not found. Run `mix wallabidi.install` or set WALLABIDI_CHROMEDRIVER_PATH."
    end
  end

  @doc "Returns the remote Chrome URL or nil."
  def chrome_url do
    case chrome() do
      {:url, url} -> url
      _ -> nil
    end
  end

  @doc "Returns the remote chromedriver URL or nil."
  def chromedriver_url do
    case chromedriver() do
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

  @doc "Returns `{:ok, path}` for local chromedriver, or `:error`. Ignores URLs."
  def chromedriver_path do
    case chromedriver() do
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
