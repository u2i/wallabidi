defmodule Wallabidi.Integration.Browser.ImportFeatureTest do
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :browser
  import Wallabidi.Feature

  feature "works", %{session: session} do
    session
    |> visit("/page_1.html")
    |> find(Query.css("body > h1"), fn el ->
      assert Element.text(el) == "Page 1"
    end)
  end
end
