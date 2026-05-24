defmodule Wallabidi.Integration.Browser.HoverTest do
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :browser
  # `refute visible?(...)` waits the full max_wait_time per Wallabidi
  # contract for the negation to stabilise.
  @moduletag slow: 10_000

  setup %{session: session} do
    {:ok, page: visit(session, "move_mouse.html")}
  end

  describe "hover/2" do
    test "hovers over the specified element", %{page: page} do
      refute page
             |> visible?(Query.text("B"))

      assert page
             |> hover(Query.css(".group"))
             |> visible?(Query.text("B"))
    end
  end
end
