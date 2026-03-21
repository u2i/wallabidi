defmodule Wallabidi.SandboxIntegrationTest do
  @moduledoc """
  Integration tests that exercise the full sandbox propagation chain
  using a real Phoenix app with Ecto, LiveView, Cachex, and Mimic.

  These tests verify that:
  1. DB data inserted in the test sandbox is visible to LiveView
  2. assign_async tasks can access the sandbox
  3. Cachex 4.1+ workers can access the sandbox via $callers
  4. Mimic stubs propagate to request processes
  5. Multiple sessions share the same sandbox
  """
  use ExUnit.Case, async: true
  use SandboxCase.Sandbox.Case
  use Wallabidi.DSL
  use Mimic

  alias Wallabidi.TestApp.{Repo, User}

  @endpoint Wallabidi.TestApp.Endpoint

  setup %{sandbox: sandbox} do
    metadata = SandboxCase.Sandbox.ecto_metadata(sandbox)
    {:ok, session} = Wallabidi.start_session(metadata: metadata)

    on_exit(fn ->
      Wallabidi.end_session(session)
    end)

    %{session: session}
  end

  describe "1. Async feature test with DB" do
    test "LiveView sees data from test sandbox", %{session: session} do
      Repo.insert!(%User{name: "Alice"})

      session
      |> visit("/users")
      |> assert_has(Query.text("Alice"))
    end
  end

  describe "3. Async with LiveView start_async" do
    test "start_async task sees sandbox data", %{session: session} do
      Repo.insert!(%User{name: "Bob"})

      session
      |> visit("/dashboard")
      |> settle()
      |> assert_has(Query.text("Stats: 1"))
    end
  end

  describe "4. Async with Cachex sandbox" do
    test "Cachex worker sees sandbox data via isolated instance", %{session: session} do
      # No need to manually clear — Cachex.Sandbox.Case gives us a clean instance
      Repo.insert!(%User{name: "Charlie"})

      session
      |> visit("/cached")
      |> assert_has(Query.text("Charlie"))
    end

    test "Cachex data doesn't leak between tests", %{session: session} do
      # This test runs after the one above. If cache isolation works,
      # "Charlie" from the previous test is NOT in our cache.
      Repo.insert!(%User{name: "Diana"})

      session
      |> visit("/cached")
      |> assert_has(Query.text("Diana"))
      |> refute_has(Query.text("Charlie"))
    end
  end

  describe "2. Async with Mimic stubs" do
    test "Mimic stub visible to LiveView process", %{session: session} do
      Mimic.stub(Wallabidi.TestApp.ExternalService, :fetch_greeting, fn ->
        "Hello from test"
      end)

      session
      |> visit("/greeting")
      |> assert_has(Query.text("Hello from test"))
    end
  end

  describe "Mox stub propagation" do
    test "Mox stub visible to LiveView process", %{session: session} do
      Mox.stub(Wallabidi.TestApp.MockWeather, :get_temperature, fn -> "72°F" end)

      session
      |> visit("/weather")
      |> assert_has(Query.text("72°F"))
    end
  end

  describe "5. Mimic stub propagation to GenServer" do
    test "GenServer spawned from LiveView sees Mimic stub", %{session: session} do
      Mimic.stub(Wallabidi.TestApp.PriceService, :fetch_price, fn ->
        "$1.23"
      end)

      session
      |> visit("/price")
      |> assert_has(Query.text("$1.23"))
    end
  end

  describe "6. Multi-session async" do
    test "two sessions share sandbox data", %{session: session1} do
      # Create a second session with the same metadata
      metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Repo, self())
      {:ok, session2} = Wallabidi.start_session(metadata: metadata)

      Repo.insert!(%User{name: "Diana"})

      # Both sessions should see the same data
      session1 |> visit("/users") |> assert_has(Query.text("Diana"))
      session2 |> visit("/users") |> assert_has(Query.text("Diana"))

      Wallabidi.end_session(session2)
    end
  end
end
