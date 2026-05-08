defmodule Wallabidi.Integration.LiveViewSmoke.AsyncTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "start_async result lands after click", %{session: session} do
    session
    |> visit(@base <> "/async")
    |> assert_has(Query.css("#status", text: "idle"))
    |> click(Query.css("#load"))
    |> assert_has(Query.css("#status", text: "done"))
    |> assert_has(Query.css("#result", text: "async result"))
  end

  test "two-phase event: synchronous assign then async overwrite", %{session: session} do
    # The handler assigns "First" synchronously and starts an async task
    # that later resolves to "Second". A driver that only awaits the
    # initial patch sees "First" and would race the async update;
    # asserting on "Second" forces the driver to wait for the async phase.
    session
    |> visit(@base <> "/async")
    |> click(Query.css("#two-phase"))
    |> assert_has(Query.css("#text", text: "Second"))
  end
end
