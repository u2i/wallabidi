defmodule Wallabidi.LiveViewDriverTest do
  use ExUnit.Case, async: true
  use Wallabidi.DSL

  @endpoint Wallabidi.TestApp.Endpoint

  setup do
    {:ok, session} =
      Wallabidi.start_session(driver: :live_view, endpoint: @endpoint)

    %{session: session}
  end

  describe "visit and find" do
    test "renders LiveView content", %{session: session} do
      session
      |> visit("/counter")
      |> assert_has(Query.css("#counter"))
      |> assert_has(Query.css("#count", text: "0"))
    end
  end

  describe "click" do
    test "clicking a phx-click button updates the page", %{session: session} do
      # Use the counter from the integration test app
      session
      |> visit("/counter")
      |> assert_has(Query.css("#count", text: "0"))
      |> click(Query.css("#inc"))
      |> assert_has(Query.css("#count", text: "1"))
    end

    test "multiple clicks", %{session: session} do
      session
      |> visit("/counter")
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> assert_has(Query.css("#count", text: "3"))
    end
  end

  describe "text" do
    test "reads element text", %{session: session} do
      session
      |> visit("/counter")
      |> find(Query.css("#count"), fn element ->
        assert Wallabidi.Element.text(element) == "0"
      end)
    end
  end

  describe "page_source" do
    test "returns current HTML", %{session: session} do
      html =
        session
        |> visit("/counter")
        |> Wallabidi.Browser.page_source()

      assert html =~ "count"
      assert html =~ "inc"
    end
  end
end
