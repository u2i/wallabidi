defmodule Wallabidi.Test do
  @moduledoc """
  Starting browser sessions for a **test suite**.

  This is the counterpart to `Wallabidi.start_session/1`, which is for an
  application's own browser use. The two are separate because a project can
  do both at once — the suite drives the app through a browser while the app
  itself scrapes a supplier site — and they need different settings in the
  same VM.

  What this adds over `Wallabidi.start_session/1`:

    * reads `config :wallabidi, :test` (falling back to the application's
      settings for anything it doesn't set)
    * honours the `WALLABIDI_DRIVER` / `WALLABIDI_BROWSER` env pin, so a CI
      lane can route a whole run to one driver
    * resolves a driver from the test's capability tags (`@tag :browser`,
      `@tag :headless`) when one isn't given explicitly

  `Wallabidi.Feature` calls this for you, so a `feature` test needs nothing
  extra. Use it directly when you start sessions by hand in a test:

      {:ok, session} = Wallabidi.Test.start_session()

  ## Why not just `Wallabidi.start_session/1`?

  It still works, and for a project whose only Wallabidi use is its test
  suite it behaves the same. It's worth switching when the application
  itself also drives a browser: only then do the two need to disagree about
  `base_url`, `max_wait_time` and the rest.
  """

  alias Wallabidi.Config

  @doc """
  Start a session for a test.

  Accepts everything `Wallabidi.start_session/1` does. Additionally:

    * `:context` — the ExUnit test context, used to resolve a driver from
      the test's capability tags.

  """
  @spec start_session(keyword) :: {:ok, Wallabidi.Session.t()} | {:error, term}
  def start_session(opts \\ []) do
    {context, opts} = Keyword.pop(opts, :context, %{})

    opts =
      opts
      |> Keyword.put_new_lazy(:driver, fn -> resolve_driver(context) end)
      |> put_new_from_test_config(:base_url)
      |> put_new_from_test_config(:max_wait_time)
      |> put_new_from_test_config(:user_agent)

    case Wallabidi.start_session(Keyword.put(opts, :__test_api__, true)) do
      {:ok, session} -> {:ok, %{session | test_session?: true}}
      other -> other
    end
  end

  @doc """
  The driver a test should run on.

  A `WALLABIDI_DRIVER` / `WALLABIDI_BROWSER` env pin wins, so a pinned CI
  lane routes every test to one driver regardless of its tags. Otherwise the
  test's capability tag selects the cheapest driver that can satisfy it.
  """
  @spec resolve_driver(map | keyword) :: atom
  def resolve_driver(context \\ %{}) do
    cond do
      pinned = Wallabidi.pinned_driver() -> pinned
      context[:browser] -> Wallabidi.driver_for(:browser)
      context[:headless] -> Wallabidi.driver_for(:headless)
      true -> test_default_driver()
    end
  end

  # `config :wallabidi, :test, driver: …` overrides the app-level `:driver`
  # for tests; without it the normal default ladder applies.
  defp test_default_driver do
    case Keyword.fetch(Config.test_config(), :driver) do
      {:ok, driver} -> driver
      :error -> Wallabidi.driver_for(:default)
    end
  end

  defp put_new_from_test_config(opts, key) do
    case Keyword.fetch(Config.test_config(), key) do
      {:ok, value} -> Keyword.put_new(opts, key, value)
      :error -> opts
    end
  end
end
