defmodule Wallabidi.Integration.Browser.SendKeysToActiveElementTest do
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :browser
  # Mixed text + :tab dispatches per-key via Input.dispatchKeyEvent;
  # each event is a separate WS round-trip.
  @moduletag slow: 10_000

  setup %{session: session} do
    page = visit(session, "forms.html")
    {:ok, %{page: page}}
  end

  describe "send_keys/2" do
    test "allows to send text to the active element", %{page: page} do
      page
      |> click(Query.text_field("Name"))
      |> send_keys(["Chris", :tab, "c@keathley.io"])

      assert page
             |> find(Query.text_field("Name"))
             |> has_value?("Chris")

      assert page
             |> find(Query.text_field("email"))
             |> has_value?("c@keathley.io")
    end
  end
end
