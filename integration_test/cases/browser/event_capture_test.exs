defmodule Wallabidi.Integration.Browser.EventCaptureTest do
  # Driver-parity test for DOM click event propagation.
  #
  # Page (/event-capture): four addEventListener invocations record
  # counters for each event-flow phase × listener-element combo:
  #
  #   root-capture      — capture phase, ancestor <div>
  #   root-bubble       — bubble phase,  ancestor <div>
  #   document-capture  — capture phase, document
  #   document-bubble   — bubble phase,  document
  #
  # Canonical W3C DOM event flow fires all four for any click that
  # reaches the target. This test asserts each driver matches that
  # contract under four dispatch mechanisms:
  #
  #   1. Wallabidi.Browser.click/2          (whatever the driver does)
  #   2. execute_script("...el.click()")    (programmatic, in-page)
  #   3. dispatchEvent(new MouseEvent...)   (synthetic, in-page)
  #
  # If a driver fails one of these, the failure diff names exactly
  # which phase × mechanism combo is broken.
  #
  # Filed as the harness behind the lavash optimistic-UI report:
  # capture-phase listeners on intermediate ancestors don't fire under
  # Lightpanda CDP, while bubble-phase listeners on document do.

  use Wallabidi.Integration.SessionCase, async: false
  # Needs a JS-capable browser (execute_script + real DOM event flow).
  # :headless runs it on Lightpanda + both Chrome drivers and excludes the
  # in-process LiveView driver, which has no execute_script.
  @moduletag :headless

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @phases ["root-capture", "root-bubble", "document-capture", "document-bubble"]

  describe "DOM event propagation parity (vanilla page)" do
    # DOM event flow is the spec; every JS-capable driver should pass this
    # (module is tagged :headless, so it runs on Lightpanda + both Chrome
    # drivers — not the in-process LiveView driver).
    test "Wallabidi.Browser.click fires all four phases", %{session: session} do
      session = visit(session, @base <> "/event-capture")
      assert_all_zero(session)

      session = click(session, Wallabidi.Query.css("#trigger-button"))

      assert_all_one(session, "click/2")
    end

    test "el.click() (programmatic) fires all four phases", %{session: session} do
      session = visit(session, @base <> "/event-capture")
      assert_all_zero(session)

      execute_script(session, "document.getElementById('trigger-button').click()")

      assert_all_one(session, "el.click()")
    end

    test "dispatchEvent(new MouseEvent('click', {bubbles: true})) fires all four", %{
      session: session
    } do
      session = visit(session, @base <> "/event-capture")
      assert_all_zero(session)

      execute_script(session, """
        var btn = document.getElementById('trigger-button');
        var ev = new MouseEvent('click', {bubbles: true, cancelable: true, view: window});
        btn.dispatchEvent(ev);
      """)

      assert_all_one(session, "dispatchEvent(MouseEvent)")
    end
  end

  describe "phx-hook lifecycle (lavash repro)" do
    test "mounted() fires on initial render and listener catches click",
         %{session: session} do
      session = visit(session, @base <> "/marker-hook")

      mounted = read_int(session, "window.__marker_mounted")

      assert mounted == 1, """
      phx-hook mounted() did NOT fire on initial render.
        window.__marker_mounted = #{inspect(mounted)}
      """

      session = click(session, Wallabidi.Query.css("#bump"))

      captured = read_int(session, "window.__marker_captured")

      assert captured == 1, """
      phx-hook capture-phase listener was attached (mounted=#{mounted}) but
      did not fire on a click that DID round-trip to the server.
        window.__marker_captured = #{inspect(captured)}
        #server-count            = #{Wallabidi.Browser.text(session, Wallabidi.Query.css("#server-count"))}
      """
    end

    test "mounted() fires on delayed mount (element appears via patch)",
         %{session: session} do
      session = visit(session, @base <> "/marker-hook")

      # Toggle hook host off, then back on. mounted() should fire again
      # when the element returns.
      session = click(session, Wallabidi.Query.css("#toggle"))
      session = click(session, Wallabidi.Query.css("#toggle"))

      mounted = read_int(session, "window.__marker_mounted")

      assert mounted >= 2, """
      phx-hook mounted() did NOT fire on delayed/dynamic mount.
        window.__marker_mounted after toggle off/on = #{inspect(mounted)} (expected >= 2)
      """

      # New hook host instance — click bump and confirm listener works.
      pre_captured = read_int(session, "window.__marker_captured")
      session = click(session, Wallabidi.Query.css("#bump"))
      post_captured = read_int(session, "window.__marker_captured")

      assert post_captured > pre_captured, """
      phx-hook listener attached during delayed mount did not fire.
        before click: __marker_captured = #{pre_captured}
        after click:  __marker_captured = #{post_captured}
      """
    end
  end

  describe "capture-phase listener under LiveView (lavash repro)" do
    # Same shape as lavash's LavashOptimistic hook: a capture-phase
    # listener on a wrapper around phx-click buttons. If the listener
    # fires, #optimistic-count bumps client-side immediately. If it
    # does not fire, only #server-count moves (after the LV round
    # trip), and we've reproduced the lavash gap.
    test "phx-click triggers wrapper's capture listener", %{session: session} do
      session = visit(session, @base <> "/capture-listener")

      assert Wallabidi.Browser.text(session, Wallabidi.Query.css("#optimistic-count")) == "0"
      assert Wallabidi.Browser.text(session, Wallabidi.Query.css("#server-count")) == "0"

      session = click(session, Wallabidi.Query.css("#bump"))

      # Both counters should have moved. The server-side count proves
      # the LV roundtrip happened; the optimistic count proves the
      # capture-phase listener fired.
      assert Wallabidi.Browser.text(session, Wallabidi.Query.css("#server-count")) == "1"

      opt = Wallabidi.Browser.text(session, Wallabidi.Query.css("#optimistic-count"))

      assert opt == "1", """
      lavash repro: capture-phase listener on a LiveView wrapper did NOT fire.
        #server-count = 1 (LV roundtrip OK)
        #optimistic-count = #{inspect(opt)} (capture listener silent)
      """
    end
  end

  # ----- helpers -----

  defp assert_all_zero(session) do
    counts = read_counters(session)

    assert counts == %{
             "root-capture" => "0",
             "root-bubble" => "0",
             "document-capture" => "0",
             "document-bubble" => "0"
           },
           "expected zero counts before click; got #{inspect(counts)}"
  end

  defp assert_all_one(session, mechanism) do
    counts = read_counters(session)

    expected = %{
      "root-capture" => "1",
      "root-bubble" => "1",
      "document-capture" => "1",
      "document-bubble" => "1"
    }

    if counts != expected do
      gap = Enum.filter(@phases, fn p -> counts[p] != "1" end)

      flunk("""
      event-flow gap via #{mechanism}:
        phases that did NOT fire: #{inspect(gap)}
        full counts: #{inspect(counts)}
      """)
    end
  end

  defp read_counters(session) do
    Enum.into(@phases, %{}, fn id ->
      text = Wallabidi.Browser.text(session, Wallabidi.Query.css("##{id}"))
      {id, text}
    end)
  end

  defp read_int(session, js) do
    me = self()
    ref = make_ref()

    Wallabidi.Browser.execute_script(session, "return #{js}", [], fn value ->
      send(me, {ref, value})
    end)

    receive do
      {^ref, value} -> normalize_int(value)
    after
      1_000 -> raise "execute_script callback did not deliver a value for #{js}"
    end
  end

  defp normalize_int(n) when is_integer(n), do: n
  defp normalize_int(n) when is_binary(n), do: String.to_integer(n)
  defp normalize_int(nil), do: 0
  defp normalize_int(other), do: other
end
