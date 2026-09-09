defmodule Wallabidi.Integration.Browser.PermissionsTest do
  use Wallabidi.Integration.SessionCase, async: false
  @moduletag :browser

  test "grant_permissions lets getUserMedia succeed without a real prompt", %{session: session} do
    page = visit(session, "/")

    execute_script(page, """
    window.__result = "pending";
    navigator.mediaDevices.getUserMedia({audio: true, video: true})
      .then(() => { window.__result = "granted"; })
      .catch(e => { window.__result = "denied:" + e.name; });
    """)

    before_grant = poll_result(session)
    assert before_grant == "denied:NotAllowedError"

    assert :ok = grant_permissions(session, [:camera, :microphone])

    execute_script(page, """
    window.__result = "pending";
    navigator.mediaDevices.getUserMedia({audio: true, video: true})
      .then(s => { window.__result = "granted:" + s.getTracks().map(t => t.kind).sort().join(","); })
      .catch(e => { window.__result = "denied:" + e.name; });
    """)

    after_grant = poll_result(session)
    assert after_grant == "granted:audio,video"
  end

  defp poll_result(session, attempts \\ 20) do
    {:ok, result} = Wallabidi.Remote.CDP.Client.evaluate(session, "window.__result")

    cond do
      result != "pending" -> result
      attempts <= 0 -> flunk("window.__result never resolved")
      true -> Process.sleep(200) && poll_result(session, attempts - 1)
    end
  end
end
