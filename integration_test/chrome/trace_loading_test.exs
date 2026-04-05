defmodule Wallabidi.Integration.Chrome.TraceLoadingTest do
  @moduledoc false

  # Raw-protocol loading tracer.
  #
  # Subscribes to every CDP event that relates to page loading, then does a
  # single navigation and prints a timeline showing exactly when each event
  # arrives relative to when we sent the navigate command, when we received
  # its response, and when the command-issuing process was able to read the
  # events from its mailbox.
  #
  # The goal is to *see* the loading state machine without having to infer it
  # from driver-level abstractions. Run with:
  #
  #     WALLABIDI_DRIVER=chrome_cdp mix test \
  #       integration_test/chrome/trace_loading_test.exs --include trace
  #
  # Tagged :trace so it's opt-in — it's diagnostic, not a pass/fail test.

  use ExUnit.Case, async: false

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.CDP.Commands
  alias Wallabidi.CDPClient

  @moduletag :trace

  # Loading-related CDP events. `Page.lifecycleEvent` is the richest —
  # it fires for every lifecycle milestone (init, DOMContentLoaded, load,
  # networkIdle, firstPaint, firstContentfulPaint, etc.) when enabled via
  # `Page.setLifecycleEventsEnabled`.
  @cdp_events [
    "Page.frameStartedLoading",
    "Page.frameNavigated",
    "Page.frameStoppedLoading",
    "Page.domContentEventFired",
    "Page.loadEventFired",
    "Page.lifecycleEvent",
    "Runtime.executionContextCreated",
    "Runtime.executionContextDestroyed"
  ]

  test "CDP raw loading trace — stale_nodes.html" do
    base_url = Application.fetch_env!(:wallabidi, :base_url)
    ws_url = Wallabidi.Chrome.Server.ws_url(Wallabidi.ChromeCDP.Server)

    {:ok, cdp_pid} = CDPClient.connect(ws_url)

    {:ok, %{"browserContextId" => ctx_id}} = CDPClient.create_browser_context(cdp_pid)

    {:ok, %{target_id: _target_id, session_id: session_id}} =
      CDPClient.create_session(cdp_pid,
        flat_session_id: true,
        browser_context_id: ctx_id
      )

    # Two collectors so we can see two different views of the same stream:
    #
    # - `wire_collector` subscribes to every event and timestamps the moment
    #   it arrives in a dedicated process's mailbox. Its receive loop does
    #   nothing else, so its timestamps are ~= the wall-clock time the
    #   WebSocketClient forwarded the frame.
    #
    # - `self()` also subscribes. We stay blocked in Page.navigate for most
    #   of the load, so events destined for us *queue* in our mailbox and
    #   we can only read them *after* navigate returns. The delta between
    #   wire_collector's timestamp and our later read timestamp is the
    #   mailbox-latency we care about.
    parent = self()
    wire_collector = spawn_link(fn -> collect_loop([], parent) end)

    Enum.each(@cdp_events, fn method ->
      WebSocketClient.subscribe(cdp_pid, method, wire_collector)
      WebSocketClient.subscribe(cdp_pid, method, self())
    end)

    # Turn on the rich lifecycle stream — fires on init, DOMContentLoaded,
    # load, networkIdle, firstPaint, firstContentfulPaint, etc.
    flat_send(
      cdp_pid,
      "Page.setLifecycleEventsEnabled",
      %{enabled: true},
      session_id
    )

    t0 = System.monotonic_time(:millisecond)

    log(t0, "--- begin navigation ---")
    log(t0, "→ Page.navigate #{base_url}/stale_nodes.html")

    {navigate_method, navigate_params} =
      Commands.navigate("#{base_url}/stale_nodes.html")

    navigate_result =
      WebSocketClient.send_command_flat(
        cdp_pid,
        navigate_method,
        Map.put(navigate_params, :sessionId, session_id),
        session_id
      )

    log(t0, "← Page.navigate response #{inspect(elem_or_value(navigate_result))}")

    # Drain events we (the main process) can now see in our mailbox. These
    # are events that arrived while we were blocked inside send_command_flat
    # above — i.e. after navigate was written to the wire but before its
    # response came back. Their "read" timestamp will lag the "wire"
    # timestamp reported by wire_collector.
    log(t0, "  (draining main-process mailbox, 2500ms window)")
    drain_main_mailbox(t0, 2500)

    # Now ask wire_collector for everything it saw. Each entry has the true
    # mailbox-arrival time. Print them ordered so we can compare against the
    # main-process read timeline above.
    send(wire_collector, {:report, self()})

    receive do
      {:wire_events, events} ->
        log(t0, "--- wire timeline (wire_collector view) ---")

        Enum.each(events, fn {ts, method, params_preview} ->
          IO.puts(
            "  wire #{pad(ts - t0)}ms  #{method}#{if params_preview, do: " " <> params_preview, else: ""}"
          )
        end)
    after
      2_000 -> flunk("wire_collector did not report")
    end

    log(t0, "--- done ---")

    # Clean up
    send(wire_collector, :stop)
    CDPClient.dispose_browser_context(cdp_pid, ctx_id)
    WebSocketClient.close(cdp_pid)
  end

  # --- helpers ---

  defp collect_loop(events, parent) do
    receive do
      {:bidi_event, method, event} ->
        ts = System.monotonic_time(:millisecond)
        params_preview = event_params_preview(method, event)
        collect_loop([{ts, method, params_preview} | events], parent)

      {:report, from} ->
        send(from, {:wire_events, Enum.reverse(events)})
        collect_loop(events, parent)

      :stop ->
        :ok
    end
  end

  defp drain_main_mailbox(t0, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_main_mailbox(t0, deadline, 0)
  end

  defp drain_main_mailbox(t0, deadline, count) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {:bidi_event, method, event} ->
          ts = System.monotonic_time(:millisecond) - t0
          params_preview = event_params_preview(method, event)

          IO.puts(
            "  read #{pad(ts)}ms  #{method}#{if params_preview, do: " " <> params_preview, else: ""}"
          )

          drain_main_mailbox(t0, deadline, count + 1)
      after
        remaining -> count
      end
    else
      count
    end
  end

  defp event_params_preview(method, event) do
    params = Map.get(event, "params", %{})

    case method do
      "Page.lifecycleEvent" -> "name=#{params["name"]}"
      "Page.frameNavigated" -> "url=#{get_in(params, ["frame", "url"])}"
      "Page.frameStartedLoading" -> "frameId=#{params["frameId"]}"
      "Page.frameStoppedLoading" -> "frameId=#{params["frameId"]}"
      "Runtime.executionContextCreated" -> "id=#{get_in(params, ["context", "id"])}"
      "Runtime.executionContextDestroyed" -> "id=#{params["executionContextId"]}"
      _ -> nil
    end
  end

  defp log(t0, msg) do
    ts = System.monotonic_time(:millisecond) - t0
    IO.puts("  test #{pad(ts)}ms  #{msg}")
  end

  defp pad(n) when is_integer(n) do
    s = Integer.to_string(n)
    String.pad_leading(s, 6)
  end

  defp elem_or_value({:ok, value}), do: {:ok, value}
  defp elem_or_value(other), do: other

  defp flat_send(pid, method, params, session_id) do
    WebSocketClient.send_command_flat(pid, method, params, session_id)
  end
end
