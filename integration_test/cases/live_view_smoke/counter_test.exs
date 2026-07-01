defmodule Wallabidi.Integration.LiveViewSmoke.CounterTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "phx-click increments server-side counter", %{session: session} do
    session
    |> visit(@base <> "/counter")
    |> assert_has(Query.css("#count", text: "0"))
    |> click(Query.css("#inc"))
    |> assert_has(Query.css("#count", text: "1"))
    |> click(Query.css("#inc"))
    |> click(Query.css("#inc"))
    |> assert_has(Query.css("#count", text: "3"))
  end
end
