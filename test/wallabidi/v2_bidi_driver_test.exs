defmodule Wallabidi.V2BiDiDriverTest do
  use ExUnit.Case, async: false

  # End-to-end smoke test. Starts the V2BiDiDriver supervisor (which
  # boots the chromium-bidi singleton) and runs a session through the
  # public Wallabidi.start_session/1 API — same path the integration
  # suite would use.

  @moduletag :browser

  alias Wallabidi.Browser

  setup do
    {:ok, _} = Wallabidi.BiDiDriver.start_link(name: Wallabidi.BiDiDriver)

    on_exit(fn ->
      try do
        Supervisor.stop(Wallabidi.BiDiDriver, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  test "start_session returns a populated V2BiDiDriver session" do
    {:ok, session} = Wallabidi.start_session(driver: :chrome_bidi_v2)

    try do
      assert session.driver == Wallabidi.BiDiDriver
      assert is_pid(session.pid)
      assert is_pid(session.bidi_pid)
      assert is_binary(session.browsing_context)

      # Drive directly through the BiDiClient to avoid Browser.visit/2's
      # base_url joining (it prepends to about:/data: URLs because they
      # have host: nil — pre-existing Browser quirk, out of scope here).
      :ok = Wallabidi.Remote.BiDi.Client.visit(session, "about:blank")
      assert {:ok, "about:blank"} = Wallabidi.Remote.BiDi.Client.current_url(session)
    after
      Wallabidi.end_session(session)
    end
  end

  test "Browser.all routes through V2.BiDiClient.find_elements for V2BiDi sessions" do
    {:ok, session} = Wallabidi.start_session(driver: :chrome_bidi_v2)

    try do
      html = "<div class='item'>a</div><div class='item'>b</div>"
      data_url = "data:text/html;charset=utf-8," <> URI.encode(html)
      :ok = Wallabidi.Remote.BiDi.Client.visit(session, data_url)

      query = Wallabidi.Query.css(".item", count: 2)
      [e1, e2] = Browser.all(session, query)
      assert is_binary(e1.bidi_shared_id)
      assert is_binary(e2.bidi_shared_id)
    after
      Wallabidi.end_session(session)
    end
  end
end
