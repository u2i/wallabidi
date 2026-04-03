defmodule Wallabidi.Integration.Element.HoverTest do
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :browser

  setup %{session: session} do
    {:ok, page: visit(session, "move_mouse.html")}
  end

  describe "hover/2" do
    test "hovers over the specified element", %{page: page} do
      page
      |> find(Query.text("B", visible: false), fn el ->
        refute Element.visible?(el)
      end)
      |> find(Query.css(".group"), fn el ->
        Element.hover(el)
      end)
      |> find(Query.text("B"), fn el ->
        assert Element.visible?(el)
      end)
    end
  end
end
