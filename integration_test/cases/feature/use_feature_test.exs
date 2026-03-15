defmodule Wallabidi.Integration.Browser.UseFeatureTest do
  use ExUnit.Case, async: true
  use Wallabidi.Feature

  @sessions 2
  feature "multi session", %{sessions: [session_1, session_2]} do
    session_1
    |> visit("/page_1.html")
    |> find(Query.css("body > h1"), fn el ->
      assert Element.text(el) == "Page 1"
    end)

    session_2
    |> visit("/page_2.html")
    |> find(Query.css("body > h1"), fn el ->
      assert Element.text(el) == "Page 2"
    end)
  end

  feature "single session", %{session: only_session} do
    only_session
    |> visit("/page_1.html")
    |> find(Query.css("body > h1"), fn el ->
      assert Element.text(el) == "Page 1"
    end)
  end

  @expected_capabilities Map.put(
                           Wallabidi.Chrome.default_capabilities(),
                           :"wallaby:test",
                           "I'm a capability"
                         )
  @sessions [[capabilities: @expected_capabilities]]
  feature "reads capabilities from session attribute", %{session: %{capabilities: capabilities}} do
    assert capabilities[:"wallaby:test"] == @expected_capabilities[:"wallaby:test"]
  end

  test "does not set up a session for non-feature tests", context do
    refute is_map_key(context, :session)
  end
end
