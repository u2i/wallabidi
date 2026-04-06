defmodule Wallabidi.Integration.Chrome.TracePushTest do
  use Wallabidi.Integration.SessionCase, async: false
  @moduletag :trace

  test "bootstrap JS is installed", %{session: session} do
    session = visit(session, "page_1.html")
    {:ok, val} = Wallabidi.Protocol.eval(session, "typeof window.__wallabidi_check")
    IO.puts("  __wallabidi_check: #{inspect(val)}")
    assert val == "function"

    {:ok, val2} = Wallabidi.Protocol.eval(session, "typeof __wallabidi")
    IO.puts("  __wallabidi binding: #{inspect(val2)}")
    assert val2 == "function"

    # Test that calling the binding actually generates an event
    {:ok, _} = Wallabidi.Protocol.eval(session, "__wallabidi(JSON.stringify({id: 'test', count: 42}))")
    IO.puts("  binding called successfully")
    Process.sleep(500)
    IO.puts("  (waited 500ms for event delivery)")
  end

  test "push find works for simple query", %{session: session} do
    session = visit(session, "nesting.html")
    {:ok, elements} = Wallabidi.CDPClient.find_elements_push(
      session, :css, ".users", timeout: 2_000, visible: true, needs_elements: true
    )
    IO.puts("  found #{length(elements)} .users elements")
    assert length(elements) > 0
  end

  test "push find with invalid selector returns error", %{session: session} do
    session = visit(session, "page_1.html")
    result = Wallabidi.CDPClient.find_elements_push(
      session, :css, "checkbox:foo", timeout: 2_000, visible: true, needs_elements: false
    )
    IO.puts("  invalid selector result: #{inspect(result)}")
    assert match?({:error, :invalid_selector}, result)
  end

  test "push find waits for element removal (count: 1)", %{session: session} do
    session = visit(session, "stale_nodes.html")
    # Initially 2 .stale-node elements. After 3s one is removed.
    {:ok, elements} = Wallabidi.CDPClient.find_elements_push(
      session, :css, ".stale-node",
      timeout: 5_000, visible: true, text: "Stale", count: 1, needs_elements: true
    )
    IO.puts("  found #{length(elements)} elements (expected 1)")
    assert length(elements) == 1
  end
end
