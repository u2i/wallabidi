defmodule Wallabidi.Integration.Chrome.TracePushTest do
  use Wallabidi.Integration.SessionCase, async: false
  @moduletag :browser
  @moduletag :cdp_only

  test "bootstrap JS is installed", %{session: session} do
    session = visit(session, "page_1.html")
    {:ok, val} = Wallabidi.Protocol.eval(session, "typeof window.__w.check")
    IO.puts("  __w.check: #{inspect(val)}")
    assert val == "function"

    {:ok, val2} = Wallabidi.Protocol.eval(session, "typeof __wallabidi")
    IO.puts("  __wallabidi binding: #{inspect(val2)}")
    assert val2 == "function"
  end

  test "opcode find works for simple query", %{session: session} do
    alias Wallabidi.CDP.Ops
    session = visit(session, "nesting.html")

    ops = Ops.new() |> Ops.query(:css, ".users") |> Ops.visible(true)
    {:ok, elements} = Wallabidi.CDPClient.find_elements_ops(session, ops, timeout: 2_000, needs_elements: true)

    IO.puts("  found #{length(elements)} .users elements")
    assert length(elements) > 0
  end

  test "opcode find with invalid selector returns error", %{session: session} do
    alias Wallabidi.CDP.Ops
    session = visit(session, "page_1.html")

    ops = Ops.new() |> Ops.query(:css, "checkbox:foo") |> Ops.visible(true)
    result = Wallabidi.CDPClient.find_elements_ops(session, ops, timeout: 2_000, needs_elements: false)

    IO.puts("  invalid selector result: #{inspect(result)}")
    assert match?({:error, :invalid_selector}, result)
  end

  test "opcode find waits for element removal (count: 1)", %{session: session} do
    alias Wallabidi.CDP.Ops
    session = visit(session, "stale_nodes.html")

    ops = Ops.new() |> Ops.query(:css, ".stale-node") |> Ops.visible(true) |> Ops.text("Stale")
    {:ok, elements} = Wallabidi.CDPClient.find_elements_ops(session, ops, timeout: 5_000, count: 1, needs_elements: true)

    IO.puts("  found #{length(elements)} elements (expected 1)")
    assert length(elements) == 1
  end
end
