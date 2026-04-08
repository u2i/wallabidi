defmodule Wallabidi.Integration.LiveView.FeatureTest do
  use ExUnit.Case, async: true
  use Wallabidi.Feature
  @moduletag :live_view_only

  # These tests verify that Feature setup correctly routes to the LiveView
  # driver when no @tag :browser is set and driver config is :live_view.

  feature "visit a LiveView and interact", %{session: session} do
    session
    |> visit("/counter")
    |> assert_has(Query.css("#count", text: "0"))
    |> click(Query.css("#inc"))
    |> assert_has(Query.css("#count", text: "1"))
  end

  feature "multiple interactions accumulate", %{session: session} do
    session
    |> visit("/counter")
    |> assert_has(Query.css("#count", text: "0"))
    |> click(Query.css("#inc"))
    |> click(Query.css("#inc"))
    |> assert_has(Query.css("#count", text: "2"))
  end

  @tag :browser
  feature "tagged :browser tests are excluded", %{session: _session} do
    # This test should be excluded by ExUnit.configure(exclude: [:browser])
    # If it runs, something is wrong with the exclusion.
    flunk("This test should have been excluded")
  end
end
