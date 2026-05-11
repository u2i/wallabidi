defmodule Wallabidi.V2.BiDiClientTest do
  use ExUnit.Case, async: false

  alias Wallabidi.Remote.ChromiumBiDi.Server, as: BidiServer
  alias Wallabidi.Session
  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient
  alias Wallabidi.Remote.Transport.BiDi

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

  defp start(base_url) do
    session_struct = %Session{id: "bc-test", url: "", driver: :test, capabilities: %{}}
    BiDi.start_session(base_url: base_url, session_struct: session_struct)
  end

  defp data_url(html), do: "data:text/html;charset=utf-8," <> URI.encode(html)

  describe "navigate/2" do
    test "returns navigation token and url for a fresh document", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      assert {:ok, %{loader_id: nav, url: url}} = BiDiClient.navigate(session, "about:blank")
      assert is_binary(nav)
      assert url == "about:blank"
    end
  end

  describe "visit/3" do
    test "blocks until the page has loaded", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      assert :ok = BiDiClient.visit(session, data_url("<title>v</title>visited"))
    end
  end

  describe "evaluate/2" do
    test "returns simple expression value", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, "about:blank")
      assert {:ok, 4} = BiDiClient.evaluate(session, "2 + 2")
    end

    test "returns string from a wrapped script with return", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, "about:blank")
      assert {:ok, "hi"} = BiDiClient.evaluate(session, "return 'hi';", [])
    end
  end

  describe "find_elements/3" do
    test "css query with explicit count returns the matching elements with sharedIds",
         %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<div class='x'>a</div><div class='x'>b</div>"))

      query = Wallabidi.Query.css(".x", count: 2)
      assert {:ok, [e1, e2]} = BiDiClient.find_elements(session, query)
      assert is_binary(e1.handle)
      assert is_binary(e2.handle)
      assert e1.handle != e2.handle
    end

    test "no matches returns ok+empty after timeout", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<div>nothing here</div>"))

      query = Wallabidi.Query.css(".missing", count: 1)
      assert {:ok, []} = BiDiClient.find_elements(session, query, timeout: 200)
    end
  end

  describe "text/2, attribute/3, displayed/2" do
    test "text returns visible textContent (whitespace collapsed)", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<p id='p'>hi  there</p>"))

      [el] = find_one(session, "#p")
      assert {:ok, "hi there"} = BiDiClient.text(session, el)
    end

    test "attribute returns named attr or nil", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<a id='a' href='/x'>l</a>"))

      [el] = find_one(session, "#a")
      assert {:ok, "/x"} = BiDiClient.attribute(session, el, "href")
      assert {:ok, nil} = BiDiClient.attribute(session, el, "nope")
    end

    test "displayed reports true for a visible element", %{base_url: base_url} do
      {:ok, session} = start(base_url)

      :ok =
        BiDiClient.visit(
          session,
          data_url("<div id='v' style='width:5px;height:5px;background:red'>v</div>")
        )

      [v] = find_one(session, "#v")
      assert {:ok, true} = BiDiClient.displayed(session, v)
    end

    test "displayed reports false for a hidden element", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<div id='h' style='display:none'>h</div>"))

      # Find the hidden element via visible: false filter so the bootstrap
      # actually surfaces it.
      query = Wallabidi.Query.css("#h", visible: false)
      {:ok, [h]} = BiDiClient.find_elements(session, query)
      assert {:ok, false} = BiDiClient.displayed(session, h)
    end
  end

  defp find_one(session, css) do
    query = Wallabidi.Query.css(css)
    {:ok, els} = BiDiClient.find_elements(session, query)
    els
  end

  describe "click/2" do
    test "click on a checkbox toggles checked + fires change", %{base_url: base_url} do
      {:ok, session} = start(base_url)

      :ok =
        BiDiClient.visit(
          session,
          data_url("""
          <input type="checkbox" id="c">
          <script>
            window.__last_change = null;
            document.getElementById('c').addEventListener('change', function() {
              window.__last_change = this.checked;
            });
          </script>
          """)
        )

      [c] = find_one(session, "#c")
      assert {:ok, nil} = BiDiClient.click(session, c)
      assert {:ok, true} = BiDiClient.evaluate(session, "window.__last_change")
    end
  end

  describe "set_value/3 + clear/3" do
    test "set_value populates a text input + fires input/change", %{base_url: base_url} do
      {:ok, session} = start(base_url)

      :ok =
        BiDiClient.visit(
          session,
          data_url("""
          <input id="t">
          <script>
            window.__events = [];
            var t = document.getElementById('t');
            ['input', 'change'].forEach(function(e) {
              t.addEventListener(e, function() { window.__events.push(e); });
            });
          </script>
          """)
        )

      [t] = find_one(session, "#t")
      assert {:ok, nil} = BiDiClient.set_value(session, t, "hello")
      assert {:ok, "hello"} = BiDiClient.attribute(session, t, "value")
      assert {:ok, ["input", "change"]} = BiDiClient.evaluate(session, "window.__events")
    end

    test "clear silent (default) wipes value without firing events", %{base_url: base_url} do
      {:ok, session} = start(base_url)

      :ok =
        BiDiClient.visit(
          session,
          data_url("""
          <input id="t" value="prefilled">
          <script>
            window.__fired = false;
            document.getElementById('t').addEventListener('change', function() {
              window.__fired = true;
            });
          </script>
          """)
        )

      [t] = find_one(session, "#t")
      assert {:ok, nil} = BiDiClient.clear(session, t)
      assert {:ok, ""} = BiDiClient.attribute(session, t, "value")
      assert {:ok, false} = BiDiClient.evaluate(session, "window.__fired")
    end
  end

  describe "send_keys/3 (text-only)" do
    test "appends text and fires input/change", %{base_url: base_url} do
      {:ok, session} = start(base_url)

      :ok =
        BiDiClient.visit(
          session,
          data_url("""
          <input id="t" value="ab">
          <script>
            window.__events = [];
            ['input', 'change'].forEach(function(e) {
              document.getElementById('t').addEventListener(e, function() {
                window.__events.push(e);
              });
            });
          </script>
          """)
        )

      [t] = find_one(session, "#t")
      assert {:ok, nil} = BiDiClient.send_keys(session, t, "cd")
      assert {:ok, "abcd"} = BiDiClient.attribute(session, t, "value")
      assert {:ok, ["input", "change"]} = BiDiClient.evaluate(session, "window.__events")
    end
  end

  describe "page_source/1, current_path/1" do
    test "page_source returns outer HTML of document element", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<html><body><p id='x'>hi</p></body></html>"))

      assert {:ok, html} = BiDiClient.page_source(session)
      assert html =~ ~s{<p id="x">hi</p>}
    end

    test "current_path returns the path component of the URL", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, "about:blank")
      # data: URLs have an empty path, but about:blank gives a clean test
      assert {:ok, path} = BiDiClient.current_path(session)
      assert path == "blank" or path == "" or path == "/"
    end
  end

  describe "current_url/1, page_title/1" do
    test "current_url returns the navigated URL", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, "about:blank")
      assert {:ok, url} = BiDiClient.current_url(session)
      assert url == "about:blank"
    end

    test "page_title returns document.title", %{base_url: base_url} do
      {:ok, session} = start(base_url)
      :ok = BiDiClient.visit(session, data_url("<title>hello</title>body"))
      assert {:ok, "hello"} = BiDiClient.page_title(session)
    end
  end
end
