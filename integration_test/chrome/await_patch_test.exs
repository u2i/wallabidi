defmodule Wallabidi.Integration.AwaitPatchTest do
  use ExUnit.Case, async: true
  use Wallabidi.DSL

  setup do
    live_url = Application.get_env(:wallabidi, :live_app_url)
    {:ok, session} = Wallabidi.start_session()
    {:ok, session: session, live_url: live_url}
  end

  describe "await_patch (via click)" do
    test "click waits for LiveView patch before returning", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> assert_has(Query.css("#count", text: "0"))
      |> click(Query.css("#inc"))
      # No settle() needed — click auto-awaits the patch
      |> assert_has(Query.css("#count", text: "1"))
    end

    test "multiple clicks await each patch", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> click(Query.css("#inc"))
      |> assert_has(Query.css("#count", text: "3"))
    end

    test "awaits slow server-side processing", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> click(Query.css("#slow-inc"))
      # Server takes 500ms — await_patch waits for the reply
      |> assert_has(Query.css("#count", text: "1"))
      |> assert_has(Query.css("#message", text: "done"))
    end
  end

  describe "await_patch (explicit)" do
    test "standalone await_patch waits for next patch", %{session: session, live_url: url} do
      session
      |> visit("#{url}/counter")
      |> assert_has(Query.css("#count", text: "0"))
      # Use execute_script to trigger a click, then await_patch explicitly
      |> execute_script("document.getElementById('inc').click()")
      |> await_patch()
      |> assert_has(Query.css("#count", text: "1"))
    end
  end

  describe "async LiveView updates" do
    test "await_patch catches async result after start_async", %{session: session, live_url: url} do
      session
      |> visit("#{url}/async")
      |> assert_has(Query.css("#status", text: "idle"))
      |> click(Query.css("#load"))
      # click awaits the first patch (handle_event reply — no DOM change)
      # The async result comes 300ms later as a second patch
      |> await_patch()
      |> assert_has(Query.css("#status", text: "done"))
      |> assert_has(Query.css("#result", text: "async result"))
    end

    test "settle works for async chains", %{session: session, live_url: url} do
      session
      |> visit("#{url}/async")
      |> click(Query.css("#load"))
      |> settle()
      |> assert_has(Query.css("#result", text: "async result"))
    end
  end

  describe "fallback on non-LiveView pages" do
    @tag :pending
    test "click works normally on plain HTML pages", %{session: session} do
      session
      |> visit("/click.html")
      |> click(Query.css("#button"))
      |> assert_has(Query.css("#log", text: "Left"))
    end
  end
end
