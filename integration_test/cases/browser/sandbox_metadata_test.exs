defmodule Wallabidi.Integration.Browser.SandboxMetadataTest do
  @moduledoc """
  Regression test for sandbox-metadata propagation via the User-Agent.

  `Wallabidi.Feature` encodes the Ecto sandbox owner allowance into the
  session metadata and the remote drivers must forward it on every
  server-side HTTP request (as a `BeamMetadata (...)` segment appended to
  the User-Agent). sandbox_shim reads that to find the sandbox owner; if a
  driver drops it, DB-backed browser tests crash with
  `DBConnection.OwnershipError`.

  This guards the Lightpanda driver in particular — it previously sent
  only `Lightpanda/1.0` with no metadata (the Chrome CDP driver already
  set it via `Network.setUserAgentOverride`).
  """
  use Wallabidi.Integration.SessionCase, async: true
  @moduletag :sandbox_metadata

  alias Wallabidi.Metadata

  @base Application.compile_env(:wallabidi, :live_app_url, "http://localhost:4321")

  @tag skip_test_session: true
  test "the driver forwards BEAM metadata in the request User-Agent" do
    metadata = %{"owner" => "test-owner", "extra" => [1, 2, 3]}

    {:ok, session} = start_test_session(metadata: metadata)

    ua =
      session
      |> visit(@base <> "/echo-user-agent")
      |> Wallabidi.Browser.text(Query.css("#ua"))

    assert ua =~ "BeamMetadata", "expected BeamMetadata segment in UA, got: #{ua}"
    assert Metadata.extract(ua) == metadata

    assert :ok = Wallabidi.end_session(session)
  end
end
