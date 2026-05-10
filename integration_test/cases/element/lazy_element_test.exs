defmodule Wallabidi.Integration.Element.LazyElementTest do
  # Phase 1 of the lazy-ref refactor: prove the opcode-only dispatch
  # path works end-to-end before flipping find/2 over.
  #
  # Constructs an Element by hand whose bidi_shared_id is `{:lazy,
  # query_ops, index}` rather than a V8 objectId. The CDP/BiDi clients
  # detect this shape and dispatch via Runtime.evaluate /
  # script.evaluate, splicing [query_ops, ["target", index]] in front of
  # the caller's ops. No V8 ref ever crosses the wire.
  #
  # The test runs against the same drivers that the other element tests
  # do — it's an integration test, not a unit test, because the round
  # trip is the point.
  use Wallabidi.Integration.SessionCase, async: true

  alias Wallabidi.Element
  alias Wallabidi.Browser

  @moduletag :headless

  setup %{session: session} do
    page = visit(session, "page_1.html")
    {:ok, %{page: page}}
  end

  describe "lazy element dispatch" do
    test "Element.text reads the resolved node via target opcode", %{page: page} do
      lazy = lazy_el(page, [["query", "css", ".user .name"]], 0)
      assert Element.text(lazy) == "Chris K."

      lazy_2 = lazy_el(page, [["query", "css", ".user .name"]], 1)
      assert Element.text(lazy_2) == "Grace H."
    end

    test "Element.attribute reads via the opcode pipeline", %{page: page} do
      # The first .blue div on page_1.html has id="1234" name="foo".
      lazy = lazy_el(page, [["query", "css", ".blue"]], 0)
      assert Element.attr(lazy, "id") == "1234"
      assert Element.attr(lazy, "name") == "foo"
    end

    test "out-of-range index surfaces as a stale_reference error", %{page: page} do
      # page_1 has fewer than 999 .user nodes; the target op should
      # produce {error: 'stale_reference'} which propagates as an
      # Elixir-side error tuple. Browser-level Element.text raises on
      # error, so check via the lower-level driver path.
      lazy = lazy_el(page, [["query", "css", ".user"]], 999)

      assert {:error, :stale_reference} =
               Wallabidi.Remote.OpsShared.dispatch_fn()
               |> dispatch(page, lazy, [[["text"]]])
    end
  end

  defp lazy_el(%{driver: driver, session_url: url} = parent, query_ops, index) do
    %Element{
      bidi_shared_id: {:lazy, query_ops, index, nil},
      parent: parent,
      driver: driver,
      url: url,
      session_url: url
    }
  end

  # Direct-dispatch helper: bypasses Browser-level error wrapping so
  # the stale_reference test can inspect the raw return.
  defp dispatch(fn_decl, session, element, args) do
    case session.driver do
      Wallabidi.Remote.Drivers.ChromeBiDi ->
        Wallabidi.Remote.BiDi.Client.call_on_element(session, element, fn_decl, args)

      _ ->
        Wallabidi.Remote.CDP.Client.call_on_element(session, element, fn_decl, args)
    end
  end

  # Suppress "unused" warnings when Browser is auto-imported by
  # SessionCase but unused in this file.
  _ = Browser
end
