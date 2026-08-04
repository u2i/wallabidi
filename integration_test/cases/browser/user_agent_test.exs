defmodule Wallabidi.Integration.Browser.UserAgentTest do
  @moduledoc """
  Covers the `:user_agent` session option.

  The cross-driver `config :wallabidi, user_agent: "..."` form can't be
  exercised here — Lightpanda takes it as a CLI flag on the shared browser
  process, so changing it means restarting the browser. This covers the
  per-session option, which is Chrome-only for that same reason.
  """
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :sandbox_metadata

  alias Wallabidi.Metadata

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")
  @custom_ua "MyScraper/1.0 (+https://example.com/bot)"

  defp request_user_agent(session) do
    session
    |> visit(@base <> "/echo-user-agent")
    |> Wallabidi.Browser.text(Query.css("#ua"))
  end

  @tag :chrome_only
  @tag skip_test_session: true
  test "user_agent replaces the User-Agent sent to the server" do
    {:ok, session} = start_test_session(user_agent: @custom_ua)

    assert request_user_agent(session) == @custom_ua

    assert :ok = Wallabidi.end_session(session)
  end

  @tag :chrome_only
  @tag skip_test_session: true
  test "user_agent composes with sandbox metadata" do
    metadata = %{"owner" => "ua-test"}

    {:ok, session} = start_test_session(user_agent: @custom_ua, metadata: metadata)

    ua = request_user_agent(session)

    # The custom UA becomes the base the metadata is appended to, so
    # sandbox propagation keeps working for a caller who sets both.
    assert String.starts_with?(ua, @custom_ua)
    assert Metadata.extract(ua) == metadata

    assert :ok = Wallabidi.end_session(session)
  end

  @tag :chrome_only
  @tag skip_test_session: true
  test "sessions can carry different User-Agents concurrently" do
    {:ok, custom} = start_test_session(user_agent: @custom_ua)
    {:ok, default} = start_test_session()

    assert request_user_agent(custom) == @custom_ua
    refute request_user_agent(default) == @custom_ua

    assert :ok = Wallabidi.end_session(custom)
    assert :ok = Wallabidi.end_session(default)
  end
end
