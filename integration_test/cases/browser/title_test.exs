defmodule Wallabidi.Integration.Browser.TitleTest do
  use Wallabidi.Integration.SessionCase, async: true

  test "finding the title", %{session: session} do
    text =
      session
      |> visit("/")
      |> page_title

    assert text == "Test Index"
  end
end
