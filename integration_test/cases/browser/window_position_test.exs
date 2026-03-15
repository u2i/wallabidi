defmodule Wallaby.Integration.Browser.WindowPositionTest do
  use Wallaby.Integration.SessionCase, async: true

  # window.moveTo and window.screenX/Y don't work in headless Chrome,
  # so this test is only meaningful in non-headless mode.
  @tag :skip
  test "getting the window position", %{session: session} do
    window_position =
      session
      |> visit("/")
      |> move_window(100, 200)
      |> window_position()

    assert %{"x" => 100, "y" => 200} = window_position
  end
end
