defmodule Wallabidi.Integration.Browser.VisibleTest do
  use Wallabidi.Integration.SessionCase, async: true

  @moduletag :browser

  describe "visible?/1" do
    setup :visit_page

    test "determines if the element is visible to the user", %{page: page} do
      page
      |> find(Query.css("#visible"))
      |> Element.visible?()
      |> assert

      page
      |> find(Query.css("#invisible", visible: false))
      |> Element.visible?()
      |> refute
    end

    test "elements positioned off-screen are still visible", %{page: page} do
      # Elements with position:absolute;top:-300px have non-zero dimensions
      # and aren't display:none — they're "visible" per WebDriver spec,
      # just not in the viewport. scrollIntoView handles scrolling at
      # interaction time.
      element = find(page, Query.css("#off-the-page"))

      assert Element.visible?(element) == true
    end
  end

  describe "visible?/2" do
    setup :visit_page

    test "returns a boolean", %{page: page} do
      assert page
             |> visible?(Query.css("#visible")) == true

      assert page
             |> visible?(Query.css("#invisible")) == false
    end
  end

  def visit_page(%{session: session}) do
    page =
      session
      |> visit("page_1.html")

    {:ok, page: page}
  end
end
