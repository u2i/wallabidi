defmodule Wallabidi.Remote.Transport.BiDiTest do
  use ExUnit.Case, async: false

  alias Wallabidi.Chrome.BidiServer
  alias Wallabidi.Session
  alias Wallabidi.Remote.Transport.BiDi
  alias Wallabidi.Remote.Transport.Protocol

  @moduletag :browser

  setup do
    {:ok, server} = BidiServer.start_link([])
    ws_url = BidiServer.ws_url(server)

    base_url =
      ws_url
      |> URI.parse()
      |> Map.put(:scheme, "http")
      |> Map.put(:path, nil)
      |> URI.to_string()

    on_exit(fn ->
      try do
        if Process.alive?(server), do: GenServer.stop(server, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, base_url: base_url}
  end

  test "start_session brings up a session with a populated browsing_context", %{
    base_url: base_url
  } do
    {:ok, session} = start(base_url)

    assert is_binary(session.browsing_context)
    assert session.browsing_context != ""
    assert is_pid(session.pid)
    assert is_pid(session.bidi_pid)
  end

  test "navigate via Protocol.cdp_send reaches the page", %{base_url: base_url} do
    {:ok, session} = start(base_url)

    {:ok, result} =
      Protocol.cdp_send(
        session,
        "browsingContext.navigate",
        %{
          "context" => session.browsing_context,
          "url" => "about:blank",
          "wait" => "complete"
        },
        []
      )

    assert is_map(result)
    assert is_binary(result["navigation"]) or is_nil(result["navigation"])
    assert result["url"] == "about:blank"
  end

  test "await_page_load resolves on browsingContext.load", %{base_url: base_url} do
    {:ok, session} = start(base_url)

    # Don't wait for "complete" — we want the navigation reply to
    # come back BEFORE the load milestone, so we can prove that
    # await_page_load actually waits for the event (or sees the
    # buffered milestone, depending on timing).
    {:ok, %{"navigation" => nav}} =
      Protocol.cdp_send(
        session,
        "browsingContext.navigate",
        %{
          "context" => session.browsing_context,
          "url" => "about:blank",
          "wait" => "none"
        },
        []
      )

    assert is_binary(nav)
    assert :ok = Protocol.await_page_load(session, nav, "load", 10_000)
  end

  test "await_page_load times out for unknown navigation id", %{base_url: base_url} do
    {:ok, session} = start(base_url)
    assert :timeout = Protocol.await_page_load(session, "no-such-nav", "load", 200)
  end

  test "bootstrap channel routes a find result", %{base_url: base_url} do
    {:ok, session} = start(base_url)

    # Navigate to a tiny page with two .item divs so the bootstrap
    # has something to find. wait: complete so the page is interactive
    # before we register the query.
    html = "<html><body><div class='item'>a</div><div class='item'>b</div></body></html>"
    data_url = "data:text/html;charset=utf-8," <> URI.encode(html)

    {:ok, _} =
      Protocol.cdp_send(
        session,
        "browsingContext.navigate",
        %{
          "context" => session.browsing_context,
          "url" => data_url,
          "wait" => "complete"
        },
        []
      )

    query_id = "q1"
    ops_json = ~s'[["query", "css", ".item"]]'
    register_snippet = Wallabidi.Remote.Bootstrap.register_js(query_id, ops_json, "null", "null")

    fn_decl = "() => { #{register_snippet} }"

    :ok = Protocol.register_find(session, query_id, 5_000)

    {:ok, _} =
      Protocol.cdp_send(
        session,
        "script.callFunction",
        %{
          "functionDeclaration" => fn_decl,
          "awaitPromise" => false,
          "target" => %{"context" => session.browsing_context}
        },
        []
      )

    assert {:ok, 2, _meta} = Protocol.await_find_result(session, query_id, 5_000)
  end

  test "session shuts down cleanly when owner exits", %{base_url: base_url} do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, session} = start(base_url, owner: self())
        send(test_pid, {:session, session})

        receive do
          :stop -> :ok
        end
      end)

    session =
      receive do
        {:session, s} -> s
      after
        15_000 -> flunk("owner never sent session")
      end

    actor_ref = Process.monitor(session.pid)
    send(owner, :stop)

    assert_receive {:DOWN, ^actor_ref, :process, _, _}, 5_000
  end

  defp start(base_url, extra \\ []) do
    session_struct = %Session{
      id: "v2-bidi-test",
      url: "",
      driver: :test,
      capabilities: %{}
    }

    BiDi.start_session(
      Keyword.merge(
        [base_url: base_url, session_struct: session_struct],
        extra
      )
    )
  end
end
