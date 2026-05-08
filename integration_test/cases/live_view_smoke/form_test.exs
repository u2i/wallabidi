defmodule Wallabidi.Integration.LiveViewSmoke.FormTest do
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Query

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  test "phx-change fires on input and server echoes back", %{session: session} do
    session
    |> visit(@base <> "/form")
    |> fill_in(Query.css("#email"), with: "alice@example.com")
    |> assert_has(Query.css("#server-email", text: "alice@example.com"))
  end

  @tag :native_form_submit
  test "phx-submit via native button click", %{session: session} do
    # The LV-driver in-process can't simulate a native form submit
    # triggered by a <button type=submit>; browser drivers can.
    session
    |> visit(@base <> "/form")
    |> fill_in(Query.css("#email"), with: "bob@example.com")
    |> click(Query.css("#submit-email"))
    |> assert_has(Query.css("#submitted", text: "bob@example.com"))
  end
end
