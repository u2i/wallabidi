defmodule Wallaby.Integration.CapabilitiesTest do
  use ExUnit.Case, async: false
  use Wallaby.DSL

  import Wallaby.SettingsTestHelpers

  alias Wallaby.Integration.SessionCase

  setup do
    ensure_setting_is_reset(:wallaby, :chromedriver)
  end

  describe "capabilities" do
    test "uses default capabilities" do
      {:ok, session} = SessionCase.start_test_session()

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallaby.end_session(session)
    end

    test "reads headless config from application config" do
      Application.put_env(:wallaby, :chromedriver, headless: true)

      {:ok, session} = SessionCase.start_test_session()

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallaby.end_session(session)
    end

    test "reads capabilities from opts" do
      capabilities = Wallaby.Chrome.default_capabilities()

      {:ok, session} = SessionCase.start_test_session(capabilities: capabilities)

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallaby.end_session(session)
    end

    test "adds the beam metadata when it is present" do
      {:ok, session} =
        SessionCase.start_test_session(metadata: %{"some" => "metadata"})

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallaby.end_session(session)
    end
  end
end
