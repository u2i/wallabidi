defmodule Wallabidi.Integration.Browser.AttrTest do
  use Wallabidi.Integration.SessionCase, async: true

  # Passes solo but occasionally flakes under load with Chrome-BiDi
  # (visit("/") races channel join under contention). Excluded from
  # the default BiDi suite; still run under CDP and Lightpanda.
  @tag :bidi_unstable
  test "can get the attributes of a query", %{session: session} do
    class =
      session
      |> visit("/")
      |> attr(Query.css("body"), "class")

    assert class =~ "bootstrap"
  end
end
