defmodule Wallabidi.Config do
  @moduledoc """
  Reads Wallabidi settings, keeping the test suite's configuration separate
  from the application's.

  A project can use Wallabidi in two unrelated ways at once: its test suite
  drives the app through a browser, and the app itself drives a browser as
  part of what it does (scraping a supplier site, rendering a PDF). Both run
  in the same VM under `mix test`, and both used to read one flat
  `config :wallabidi` — so the suite's `base_url` and `max_wait_time` would
  silently govern the application's sessions.

  Settings therefore live in two places:

      # the application's own browser use — read by Wallabidi.start_session/1
      config :wallabidi,
        driver: :lightpanda,
        base_url: "https://supplier.example.com",
        max_wait_time: 10_000

      # the test suite's — read by Wallabidi.Test.start_session/1
      config :wallabidi, :test,
        driver: :chrome_cdp,
        base_url: "http://localhost:4002",
        max_wait_time: 3_000

  `config :wallabidi, :test` falls back to the top-level value for any key it
  doesn't set, so existing single-namespace projects keep working unchanged.
  """

  @test_namespace :test

  @doc """
  Fetch `key` for the application's own Wallabidi use.
  """
  @spec get(atom, term) :: term
  def get(key, default \\ nil) do
    Application.get_env(:wallabidi, key, default)
  end

  @doc """
  Fetch `key` for the test suite, falling back to the application-level
  value when `config :wallabidi, :test` doesn't set it.
  """
  @spec get_test(atom, term) :: term
  def get_test(key, default \\ nil) do
    case Keyword.fetch(test_config(), key) do
      {:ok, value} -> value
      :error -> get(key, default)
    end
  end

  @doc """
  Fetch `key` for whichever mode the calling session belongs to.

  Sessions started by `Wallabidi.Test.start_session/1` are flagged, so
  reads made while driving them (`visit/2`'s base URL, the auto-wait
  budget) resolve against the test namespace; everything else resolves
  against the application's.
  """
  @spec get_for(Wallabidi.Session.t() | nil, atom, term) :: term
  def get_for(session, key, default \\ nil)

  def get_for(%{test_session?: true}, key, default), do: get_test(key, default)
  def get_for(_session, key, default), do: get(key, default)

  @doc """
  The raw `config :wallabidi, :test` keyword list.
  """
  @spec test_config() :: keyword
  def test_config do
    case Application.get_env(:wallabidi, @test_namespace, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
