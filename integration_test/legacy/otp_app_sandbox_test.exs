defmodule Wallabidi.Integration.Legacy.OtpAppSandboxTest do
  @moduledoc """
  Verifies the legacy otp_app sandbox path: when SandboxCase is not set up,
  Wallabidi.Feature falls back to maybe_checkout_repos/1, which uses repo_started?/1
  to find running repos and checks them out via Ecto.Adapters.SQL.Sandbox.

  If repo_started?/1 is broken (always returns false), no repos are checked out,
  metadata is empty, the browser gets no sandbox cookie, and the LiveView cannot
  see data inserted in the test transaction — causing the assert_has to fail.
  """
  use ExUnit.Case, async: false
  use Wallabidi.Feature

  alias Wallabidi.Integration.LiveApp.{Repo, User}

  feature "sandbox data inserted in test is visible to LiveView", %{session: session} do
    Repo.insert!(%User{name: "LegacyUser"})

    session
    |> visit("/users")
    |> assert_has(Query.text("LegacyUser"))
  end

  feature "sandbox is rolled back between tests — previous test's data is gone",
          %{session: session} do
    session
    |> visit("/users")
    |> refute_has(Query.text("LegacyUser"))
  end
end
