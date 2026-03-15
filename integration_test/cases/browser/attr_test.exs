defmodule Wallabidi.Integration.Browser.AttrTest do
  use Wallabidi.Integration.SessionCase, async: true

  test "can get the attributes of a query", %{session: session} do
    class =
      session
      |> visit("/")
      |> attr(Query.css("body"), "class")

    assert class =~ "bootstrap"
  end
end
