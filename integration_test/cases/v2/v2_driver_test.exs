defmodule Wallabidi.Integration.V2.DriverTest do
  @moduledoc """
  Exercises Wallabidi.LightpandaDriver via the Driver behaviour itself.

  Doesn't yet go through Wallabidi.Browser.* — that path has hard
  couplings to Wallabidi.SessionProcess that V2.Session doesn't
  satisfy. This proves the V2 stack covers the Driver behaviour
  surface end-to-end against Lightpanda.
  """
  use ExUnit.Case, async: false

  @moduletag :v2

  alias Wallabidi.LightpandaDriver, as: V2Driver

  setup do
    {:ok, session} = V2Driver.start_session([])
    on_exit(fn -> V2Driver.end_session(session) end)
    %{session: session}
  end

  describe "V2Driver via @behaviour Wallabidi.Driver" do
    test "visit + current_url + page_title", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      url = base <> "index.html"

      assert :ok = V2Driver.visit(session, url)
      assert {:ok, ^url} = V2Driver.current_url(session)

      assert {:ok, title} = V2Driver.page_title(session)
      assert is_binary(title)
    end

    test "find_elements + click + text + attribute", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = V2Driver.visit(session, base <> "index.html")

      {:ok, [header]} = V2Driver.find_elements(session, Wallabidi.Query.css("#header"))
      assert {:ok, "header"} = V2Driver.attribute(header, "id")

      {:ok, text} = V2Driver.text(header)
      assert is_binary(text)
      assert byte_size(text) > 0

      assert {:ok, true} = V2Driver.displayed(header)
      assert {:ok, _} = V2Driver.click(header)
    end

    test "set_value + clear + send_keys round-trip", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = V2Driver.visit(session, base <> "forms.html")

      {:ok, [input]} = V2Driver.find_elements(session, Wallabidi.Query.css("#name_field"))

      assert {:ok, _} = V2Driver.set_value(input, "alice")
      assert {:ok, "alice"} = V2Driver.attribute(input, "value")

      assert {:ok, _} = V2Driver.clear(input)
      assert {:ok, ""} = V2Driver.attribute(input, "value")

      assert {:ok, _} = V2Driver.send_keys(input, ["bob"])
      assert {:ok, "bob"} = V2Driver.attribute(input, "value")
    end

    test "execute_script + page_source", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = V2Driver.visit(session, base <> "index.html")

      assert {:ok, 4} = V2Driver.execute_script(session, "2 + 2", [])
      assert {:ok, html} = V2Driver.page_source(session)
      assert html =~ ~r/<html/i
    end

    test "cookies round-trip", %{session: session} do
      base = Application.fetch_env!(:wallabidi, :base_url)
      :ok = V2Driver.visit(session, base <> "index.html")

      assert {:ok, _} = V2Driver.set_cookie(session, "v2drv", "yes", url: base)
      {:ok, cookies} = V2Driver.cookies(session)
      assert Enum.any?(cookies, fn c -> c["name"] == "v2drv" and c["value"] == "yes" end)
    end
  end
end
