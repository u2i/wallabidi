defmodule Wallabidi.Transport.PerSessionWS do
  @moduledoc false

  # Transport: ONE shared browser process per BEAM, ONE V2.WebSocket
  # PER SESSION. This matches legacy Wallabidi.Lightpanda's model —
  # Lightpanda accepts many WS connections to the same binary, and
  # opens a fresh CDP session on each WS via Target.createTarget +
  # attachToTarget.
  #
  # Compared to SharedWS: avoids contention on a single WS for
  # browsers that don't cleanly multiplex CDP sessions. Compared to
  # IsolatedProcess: avoids paying browser-startup cost per session.
  #
  # The shared browser-process pid lives in a Holder (the driver
  # supervisor's sole child).

  @behaviour Wallabidi.Transport

  alias Wallabidi.Transport
  alias Wallabidi.WebSocket

  @impl true
  def acquire(opts) do
    ws_url =
      case Keyword.get(opts, :ws_url) do
        url when is_binary(url) -> url
        _ -> resolve_url(opts)
      end

    with {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- Transport.attach_to_target(ws_pid, target_id) do
      caps = Keyword.get(opts, :extra_capabilities, %{})
      teardown = fn _session -> Transport.close_ws(ws_pid) end

      {:ok,
       %{
         ws_pid: ws_pid,
         target_id: target_id,
         session_id: session_id,
         browser_context_id: nil,
         teardown_fun: teardown,
         capabilities:
           Map.merge(caps, %{
             target_id: target_id,
             flat_session_id: true,
             shared_browser: true
           })
       }}
    end
  end

  defp resolve_url(opts) do
    # Caller passes a 0-arity function that returns the shared
    # browser's WS URL. For Lightpanda this is
    # `fn -> Lightpanda.Server.ws_url(server_name) end`.
    url_fun = Keyword.fetch!(opts, :url_fun)
    url_fun.()
  end
end
