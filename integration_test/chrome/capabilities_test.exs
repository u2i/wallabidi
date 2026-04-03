defmodule Wallabidi.Integration.CapabilitiesTest do
  use ExUnit.Case, async: true
  use Wallabidi.DSL

  alias Wallabidi.Integration.SessionCase

  describe "capabilities" do
    test "uses default capabilities" do
      {:ok, session} = SessionCase.start_test_session()

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallabidi.end_session(session)
    end

    test "headless option is accepted" do
      {:ok, session} = SessionCase.start_test_session(headless: true)

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallabidi.end_session(session)
    end

    test "reads capabilities from opts" do
      capabilities = Wallabidi.Chrome.default_capabilities()

      {:ok, session} = SessionCase.start_test_session(capabilities: capabilities)

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallabidi.end_session(session)
    end

    test "adds the beam metadata when it is present" do
      {:ok, session} =
        SessionCase.start_test_session(metadata: %{"some" => "metadata"})

      session
      |> visit("page_1.html")
      |> assert_has(Query.text("Page 1"))

      assert :ok = Wallabidi.end_session(session)
    end
  end
end
