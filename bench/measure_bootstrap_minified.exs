#!/usr/bin/env elixir

# Compare wire+compile cost of the minified bundle vs the unminified
# source. Both are Page.addScriptToEvaluateOnNewDocument calls on a
# warm session — isolates the JS payload size effect.

alias Wallabidi.{CDPClient, Transport}
alias Wallabidi.Transport.Session, as: V2Session
alias Wallabidi.WebSocket

defmodule M do
  def fresh_session(ws_pid) do
    {:ok, %{"browserContextId" => ctx_id}} =
      WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{})

    {:ok, %{"targetId" => target_id}} =
      WebSocket.send_sync(ws_pid, "Target.createTarget", %{
        url: "about:blank",
        browserContextId: ctx_id
      })

    {:ok, session_id} = Transport.attach_to_target(ws_pid, target_id)

    session_struct = %Wallabidi.Session{
      id: "bench-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      protocol: nil,
      bidi_pid: ws_pid,
      browsing_context: session_id,
      capabilities: %{target_id: target_id, flat_session_id: true}
    }

    {:ok, session} =
      V2Session.start_link(
        ws_pid: ws_pid,
        init_fun: fn -> {:ok, session_struct} end,
        teardown_fun: fn _ -> :ok end
      )

    {session, ctx_id}
  end

  def cleanup(session, ws_pid, ctx_id) do
    Transport.dispose_browser_context(ws_pid, ctx_id)
    V2Session.stop(session)
  end

  def time_send(session, source) do
    t0 = System.monotonic_time(:microsecond)
    {:ok, _} = CDPClient.cdp_send(session, "Page.addScriptToEvaluateOnNewDocument", %{source: source})
    t1 = System.monotonic_time(:microsecond)
    t1 - t0
  end

  def stats(name, samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    avg = Enum.sum(samples) / n / 1000
    p50 = Enum.at(sorted, div(n, 2)) / 1000
    p90 = Enum.at(sorted, min(div(n * 9, 10), n - 1)) / 1000
    IO.puts("  #{String.pad_trailing(name, 30)} avg=#{Float.round(avg, 2)}ms p50=#{Float.round(p50, 2)}ms p90=#{Float.round(p90, 2)}ms")
    avg
  end
end

# Read both files
src_path = Path.join([__DIR__, "..", "priv", "wallabidi.js"])
min_path = Path.join([__DIR__, "..", "priv", "wallabidi.min.js"])

src_body = File.read!(src_path)
min_body = File.read!(min_path)

src_iife = "(function() {\n" <> src_body <> "\n})()"
min_iife = "(function() {\n" <> min_body <> "\n})()"

IO.puts("Source IIFE:    #{byte_size(src_iife)} bytes")
IO.puts("Minified IIFE:  #{byte_size(min_iife)} bytes")
IO.puts("Reduction:      #{Float.round((1 - byte_size(min_iife) / byte_size(src_iife)) * 100, 1)}%")

{:ok, server} = Wallabidi.Chrome.Server.start_link(name: nil)
ws_url = Wallabidi.Chrome.Server.ws_url(server)
{:ok, ws_pid} = WebSocket.start_link(ws_url)

# One session, warm (so Page domain is initialized — isolates the
# script-send cost from the cold-Page-domain cost).
{session, ctx_id} = M.fresh_session(ws_pid)
:ok = CDPClient.enable_page_lifecycle_events(session)
:ok = CDPClient.install_bootstrap(session)

n = 30

# Warm
Enum.each(1..3, fn _ ->
  M.time_send(session, src_iife)
  M.time_send(session, min_iife)
end)

IO.puts("\n=== Per-call cost on warm session (n=#{n}, serial) ===")
src_samples = for _ <- 1..n, do: M.time_send(session, src_iife)
min_samples = for _ <- 1..n, do: M.time_send(session, min_iife)

src_avg = M.stats("source IIFE", src_samples)
min_avg = M.stats("minified IIFE", min_samples)

IO.puts("\n=== Δ ===")
IO.puts("    saved per call: #{Float.round(src_avg - min_avg, 2)}ms (#{Float.round((1 - min_avg / src_avg) * 100, 1)}%)")
IO.puts("    × 343 sessions: #{Float.round((src_avg - min_avg) * 343 / 1000, 2)}s cumulative")
IO.puts("    × 343 / mc8:    #{Float.round((src_avg - min_avg) * 343 / 8 / 1000, 2)}s wallclock")

M.cleanup(session, ws_pid, ctx_id)

# Now measure full install_bootstrap (includes Page-domain warmup cost,
# which dominates and is unaffected by JS size).
IO.puts("\n=== Full install_bootstrap on FRESH sessions (n=20) ===")

full_samples = for _ <- 1..20 do
  {s, c} = M.fresh_session(ws_pid)
  :ok = CDPClient.enable_page_lifecycle_events(s)
  t0 = System.monotonic_time(:microsecond)
  :ok = CDPClient.install_bootstrap(s)
  t1 = System.monotonic_time(:microsecond)
  M.cleanup(s, ws_pid, c)
  t1 - t0
end

M.stats("full install_bootstrap", full_samples)

WebSocket.close(ws_pid)
GenServer.stop(server, :normal)
