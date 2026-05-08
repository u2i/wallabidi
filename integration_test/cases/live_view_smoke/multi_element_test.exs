defmodule Wallabidi.Integration.LiveViewSmoke.MultiElementTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "list renders, click appends, count increases", %{session: session} do
    session
    |> visit(@base <> "/multi")
    |> assert_has(Query.css(".message", count: 2))
    |> click(Query.css("#add"))
    |> assert_has(Query.css(".message", count: 3))
  end
end
