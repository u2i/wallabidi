defmodule Wallabidi.Remote.Transport.IsolatedProcess do
  @moduledoc false

  # Transport: a fresh browser process AND a fresh WebSocket per
  # session. The slowest model — every session pays a binary-startup
  # cost — but cleanest isolation: each session gets a private
  # browser, no contention with peers.
  #
  # Suitable when the browser doesn't multiplex CDP sessions well over
  # one connection (or has bugs that surface under concurrent load).
  # Currently the default Lightpanda transport.

  @behaviour Wallabidi.Remote.Transport

  alias Wallabidi.Remote.Transport
  alias Wallabidi.Remote.WebSocket

  @impl true
  def acquire(opts) do
    {:ok, ws_url, server_pid} = ensure_server(opts)

    with {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- Transport.attach_to_target(ws_pid, target_id) do
      caps = Keyword.get(opts, :extra_capabilities, %{})

      teardown = fn _session ->
        Transport.close_ws(ws_pid)
        if is_pid(server_pid), do: stop_server(server_pid)
        :ok
      end

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
             server_pid: server_pid
           })
       }}
    else
      err ->
        # Failed mid-bring-up: kill the spawned binary so we don't leak
        # a Lightpanda process per failed session.
        if is_pid(server_pid), do: stop_server(server_pid)
        err
    end
  end

  defp ensure_server(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) ->
        {:ok, url, nil}

      _ ->
        spawn_fun = Keyword.fetch!(opts, :spawn_fun)
        {:ok, server} = spawn_fun.()
        url_fun = Keyword.fetch!(opts, :url_fun)
        ws_url = url_fun.(server)
        {:ok, ws_url, server}
    end
  end

  defp stop_server(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      _, _ -> :ok
    end

    :ok
  end
end
