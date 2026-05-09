#!/usr/bin/env bash
# LP+LiveView regression suite.
#
# Lightpanda 0.2.9 and 1.0.0-nightly.6065 both fail to carry HTTP
# cookies into WebSocket upgrade requests, which breaks Phoenix
# LiveView (Phoenix sees `connect_info.session = nil`, rejects the
# channel join with `stale`, and the LV client falls back to a full
# page request — interactive features never work).
#
# This script re-runs every angle we know of so we can quickly tell
# whether a future LP version has fixed any of them.
#
# Probes (in order):
#   1. Direct test: navigate to /counter, dump connect_info.session.
#   2. Network.setExtraHTTPHeaders with Cookie: ...
#   3. Network.setCookie via the cookie jar.
#   4. document.cookie = "..." via Runtime.evaluate.
#   5. Capability probes: Network.getAllCookies, Network.getCookies, etc.
#
# Each probe writes a single PASS/FAIL line. If everything passes,
# LP can drive Phoenix LiveView and we should drop the
# `:lightpanda_ni` blanket from the smoke suite.
#
# Usage:
#   bench/lp_lv_regression.sh                    # uses LP from PATH or known location
#   LP=/path/to/lightpanda bench/lp_lv_regression.sh
#
# Output:
#   bench/lp_lv_regression.<lp_version>.log  — full server + LP server log
#   stdout                                   — PASS/FAIL summary

set -u
cd "$(dirname "$0")/.."

# --- Resolve LP binary --------------------------------------------------------

LP="${LP:-}"
if [[ -z "$LP" ]]; then
  for cand in \
    "/Users/tom/dev/perf_bench/_build/lightpanda-aarch64-macos" \
    "_build/lightpanda-aarch64-macos" \
    "$(command -v lightpanda 2>/dev/null)"
  do
    if [[ -n "$cand" && -x "$cand" ]]; then LP="$cand"; break; fi
  done
fi
if [[ -z "$LP" ]]; then
  echo "ERROR: no Lightpanda binary found. Set LP=/path/to/lightpanda."
  exit 2
fi

LP_VERSION=$("$LP" version 2>&1 | head -1 | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g; s/^_//; s/_$//')
LP_VERSION="${LP_VERSION:-unknown}"
OUT="bench/lp_lv_regression.${LP_VERSION}.log"

echo "LP binary:  $LP"
echo "LP version: $LP_VERSION"
echo "Log file:   $OUT"
echo

# --- Patch Phoenix.LiveView.Channel to dump connect_info on join -------------

CHANNEL=deps/phoenix_live_view/lib/phoenix_live_view/channel.ex
TMPDIR=$(mktemp -d -t lp_lv_regression.XXXXXX)

cleanup() {
  [[ -n "${LV_PID:-}" ]] && kill "$LV_PID" 2>/dev/null || true
  [[ -n "${LP_PID:-}" ]] && kill "$LP_PID" 2>/dev/null || true
  if [[ -f "${CHANNEL}.bak" ]]; then
    mv "${CHANNEL}.bak" "$CHANNEL"
    MIX_ENV=test mix deps.compile phoenix_live_view --force > /dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

cp "$CHANNEL" "${CHANNEL}.bak"
python3 - <<'PY'
import pathlib
p = pathlib.Path("deps/phoenix_live_view/lib/phoenix_live_view/channel.ex")
s = p.read_text()
needle = "      {:ok, %Session{} = verified} ->\n        %Phoenix.Socket{private: %{connect_info: connect_info}} = phx_socket\n\n        case connect_info do"
patch  = "      {:ok, %Session{} = verified} ->\n        %Phoenix.Socket{private: %{connect_info: connect_info}} = phx_socket\n        IO.puts(:stderr, \"LP_REGRESSION_CONN_INFO \" <> inspect(connect_info))\n\n        case connect_info do"
if needle not in s:
    raise SystemExit("channel.ex needle not found — Phoenix LV may have changed shape")
p.write_text(s.replace(needle, patch))
PY

MIX_ENV=test mix deps.compile phoenix_live_view --force > /dev/null 2>&1

# --- Boot the LV app endpoint -------------------------------------------------

cat > "$TMPDIR/endpoint.exs" <<'EOF'
Logger.configure(level: :info)
Application.put_env(:wallabidi, Wallabidi.Integration.LiveApp.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4321],
  server: true,
  check_origin: false,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "integration_test"],
  render_errors: [formats: [html: Wallabidi.Integration.LiveApp.ErrorHTML], layout: false]
)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Wallabidi.Integration.PubSub)
{:ok, _} = Wallabidi.Integration.LiveApp.Endpoint.start_link()
IO.puts(">>> ready")
Process.sleep(:infinity)
EOF

> "$OUT"
MIX_ENV=test elixir -S mix run --no-halt "$TMPDIR/endpoint.exs" > "$OUT" 2>&1 &
LV_PID=$!

for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf http://localhost:4321/counter > /dev/null 2>&1; then
    echo "endpoint ready (${i}s)"
    break
  fi
  sleep 1
done

# Capture a real session cookie.
SESSION_COOKIE=$(curl -i -s http://localhost:4321/counter 2>/dev/null \
  | grep -i "^set-cookie" \
  | sed 's/^[Ss]et-[Cc]ookie: //; s/;.*//' \
  | tr -d '\r')
if [[ -z "$SESSION_COOKIE" ]]; then
  echo "ERROR: no Set-Cookie from /counter. Bailing."
  exit 2
fi
SESSION_COOKIE_VALUE="${SESSION_COOKIE#_live_test=}"
echo "Captured cookie: ${SESSION_COOKIE_VALUE:0:30}..."
echo

# --- Boot LP serve ------------------------------------------------------------

"$LP" serve --host 127.0.0.1 --port 49606 > "$TMPDIR/lp_serve.log" 2>&1 &
LP_PID=$!
sleep 2

# Common Elixir prelude — opens a CDP session on the running LP.
cat > "$TMPDIR/prelude.exs" <<'EOF'
{:ok, ws} = Wallabidi.WebSocket.start_link("ws://127.0.0.1:49606")
{:ok, ctx} = Wallabidi.WebSocket.send_sync(ws, "Target.createBrowserContext", %{})
{:ok, tgt} = Wallabidi.WebSocket.send_sync(ws, "Target.createTarget", %{"url" => "about:blank", "browserContextId" => ctx["browserContextId"]})
{:ok, attach} = Wallabidi.WebSocket.send_sync(ws, "Target.attachToTarget", %{"targetId" => tgt["targetId"], "flatten" => true})
sess = attach["sessionId"]
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Page.enable", %{"sessionId" => sess})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Network.enable", %{"sessionId" => sess})
EOF

# --- Probe runner -------------------------------------------------------------

run_probe() {
  local label="$1"
  local script="$2"

  echo "--- PROBE: $label ---" >> "$OUT"

  local script_file="$TMPDIR/probe.exs"
  { cat "$TMPDIR/prelude.exs"; echo; printf '%s\n' "$script"; echo "System.halt(0)"; } > "$script_file"

  local before
  before=$(grep -c "LP_REGRESSION_CONN_INFO" "$OUT" 2>/dev/null || true)

  MIX_ENV=test elixir -S mix run --no-halt "$script_file" >> "$OUT" 2>&1

  local after
  after=$(grep -c "LP_REGRESSION_CONN_INFO" "$OUT" 2>/dev/null || true)

  if [[ "$after" -le "$before" ]]; then
    printf "  %-50s SKIP (no channel-join — page didn't load)\n" "$label"
    return
  fi

  local last_line
  last_line=$(grep "LP_REGRESSION_CONN_INFO" "$OUT" | tail -1)

  if echo "$last_line" | grep -q "session: nil"; then
    printf "  %-50s FAIL (session: nil)\n" "$label"
  else
    printf "  %-50s PASS (session populated)\n" "$label"
  fi
}

# Probe 1 — bare navigation, no injection at all. PASS only if LP carries
# the Set-Cookie response cookie onto the WS upgrade.
run_probe "1) bare nav (Set-Cookie response)" '
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Page.navigate", %{"sessionId" => sess, "url" => "http://localhost:4321/counter"})
:timer.sleep(3000)
'

# Probe 2 — Network.setExtraHTTPHeaders w/ Cookie before navigation.
run_probe "2) Network.setExtraHTTPHeaders Cookie" "
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Network.setExtraHTTPHeaders\", %{
  \"sessionId\" => sess,
  \"headers\" => %{\"Cookie\" => \"$SESSION_COOKIE\"}
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Page.navigate\", %{\"sessionId\" => sess, \"url\" => \"http://localhost:4321/counter\"})
:timer.sleep(3000)
"

# Probe 3 — Network.setCookie cookie jar before navigation.
run_probe "3) Network.setCookie cookie jar" "
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Network.setCookie\", %{
  \"sessionId\" => sess,
  \"name\" => \"_live_test\",
  \"value\" => \"$SESSION_COOKIE_VALUE\",
  \"domain\" => \"localhost\",
  \"path\" => \"/\",
  \"url\" => \"http://localhost:4321/\"
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Page.navigate\", %{\"sessionId\" => sess, \"url\" => \"http://localhost:4321/counter\"})
:timer.sleep(3000)
"

# Probe 4 — document.cookie via Runtime.evaluate after a first nav. The
# second nav's WS upgrade is what we measure.
run_probe "4) document.cookie via Runtime.evaluate" "
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Runtime.enable\", %{\"sessionId\" => sess})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Page.navigate\", %{\"sessionId\" => sess, \"url\" => \"http://localhost:4321/counter\"})
:timer.sleep(2000)
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Runtime.evaluate\", %{
  \"sessionId\" => sess,
  \"expression\" => \"document.cookie = '$SESSION_COOKIE; path=/'\"
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, \"Page.navigate\", %{\"sessionId\" => sess, \"url\" => \"http://localhost:4321/counter\"})
:timer.sleep(3000)
"

# --- Capability probes (informational) ----------------------------------------

echo
echo "Capability probes (does LP know these CDP methods?):"

probe_capability() {
  local method="$1"
  local params="$2"

  cat > "$TMPDIR/cap.exs" <<EOF
$(cat "$TMPDIR/prelude.exs")
result = Wallabidi.WebSocket.send_sync(ws, "$method", Map.put($params, "sessionId", sess))
case result do
  {:ok, _} -> IO.puts(:stdio, "CAP_RESULT OK")
  {:error, {-31998, "UnknownMethod"}} -> IO.puts(:stdio, "CAP_RESULT UNKNOWN")
  {:error, e} -> IO.puts(:stdio, "CAP_RESULT ERR " <> inspect(e))
end
System.halt(0)
EOF
  local result
  result=$(MIX_ENV=test elixir -S mix run --no-halt "$TMPDIR/cap.exs" 2>/dev/null \
    | grep "CAP_RESULT" | head -1 | sed 's/^CAP_RESULT //')
  printf "  %-50s %s\n" "$method" "${result:-NO RESPONSE}"
}

probe_capability "Network.getAllCookies"        "%{}"
probe_capability "Network.getCookies"           '%{"urls" => ["http://localhost:4321/"]}'
probe_capability "Network.deleteCookies"        '%{"name" => "x", "url" => "http://localhost:4321/"}'

# --- Reset-related capability probes ----------------------------------------
# These are the methods Wallabidi.Driver.reset/1 would call on a checkin
# in a session pool. UNKNOWN means LP doesn't implement it; OK means the
# method dispatched (doesn't necessarily mean it has correct behavior —
# see the behavior probes below).
echo
echo "Reset capability probes (needed for session pool reset_strategy=:reset):"

probe_capability "Network.clearBrowserCache"    "%{}"
probe_capability "Network.clearBrowserCookies"  "%{}"
probe_capability "Storage.clearDataForOrigin"   '%{"origin" => "http://localhost:4321", "storageTypes" => "all"}'
probe_capability "Storage.clearCookies"         '%{}'
probe_capability "ServiceWorker.unregister"     '%{"scopeURL" => "http://localhost:4321/"}'

# --- Reset BEHAVIOR probes (does it actually clear?) -----------------------
# Capability-OK doesn't mean correct. These set state, run the alleged
# reset, then verify state is gone. PASS only if the verifier sees zero.
echo
echo "Reset behavior probes (does the method actually clear state?):"

probe_behavior() {
  local label="$1"
  local script="$2"

  cat > "$TMPDIR/behavior.exs" <<EOF
$(cat "$TMPDIR/prelude.exs")
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Runtime.enable", %{"sessionId" => sess})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Page.navigate", %{"sessionId" => sess, "url" => "http://localhost:4321/counter"})
:timer.sleep(2000)
$script
System.halt(0)
EOF
  local result
  result=$(MIX_ENV=test elixir -S mix run --no-halt "$TMPDIR/behavior.exs" 2>/dev/null \
    | grep "BEHAVIOR_RESULT" | head -1 | sed 's/^BEHAVIOR_RESULT //')
  printf "  %-50s %s\n" "$label" "${result:-NO RESPONSE}"
}

# Probe A — localStorage cleared by Storage.clearDataForOrigin?
probe_behavior "localStorage cleared by Storage.clearDataForOrigin" '
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "expression" => "localStorage.setItem(\"k\", \"v\")"
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Storage.clearDataForOrigin", %{
  "sessionId" => sess,
  "origin" => "http://localhost:4321",
  "storageTypes" => "all"
})
result = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "expression" => "localStorage.getItem(\"k\")",
  "returnByValue" => true
})
case result do
  {:ok, %{"result" => %{"value" => nil}}} -> IO.puts("BEHAVIOR_RESULT PASS")
  {:ok, %{"result" => %{"value" => v}}} -> IO.puts("BEHAVIOR_RESULT FAIL (still has value: " <> inspect(v) <> ")")
  other -> IO.puts("BEHAVIOR_RESULT ERR " <> inspect(other))
end
'

# Probe B — cookies cleared by Network.clearBrowserCookies?
probe_behavior "cookies cleared by Network.clearBrowserCookies" '
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Network.setCookie", %{
  "sessionId" => sess,
  "name" => "test_reset_probe",
  "value" => "abc",
  "domain" => "localhost",
  "path" => "/",
  "url" => "http://localhost:4321/"
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Network.clearBrowserCookies", %{"sessionId" => sess})
result = Wallabidi.WebSocket.send_sync(ws, "Network.getCookies", %{
  "sessionId" => sess,
  "urls" => ["http://localhost:4321/"]
})
case result do
  {:ok, %{"cookies" => []}} -> IO.puts("BEHAVIOR_RESULT PASS")
  {:ok, %{"cookies" => cs}} -> IO.puts("BEHAVIOR_RESULT FAIL (cookies remain: " <> Integer.to_string(length(cs)) <> ")")
  other -> IO.puts("BEHAVIOR_RESULT ERR " <> inspect(other))
end
'

# Probe C — sessionStorage cleared by Storage.clearDataForOrigin?
probe_behavior "sessionStorage cleared by Storage.clearDataForOrigin" '
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "expression" => "sessionStorage.setItem(\"k\", \"v\")"
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Storage.clearDataForOrigin", %{
  "sessionId" => sess,
  "origin" => "http://localhost:4321",
  "storageTypes" => "all"
})
result = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "expression" => "sessionStorage.getItem(\"k\")",
  "returnByValue" => true
})
case result do
  {:ok, %{"result" => %{"value" => nil}}} -> IO.puts("BEHAVIOR_RESULT PASS")
  {:ok, %{"result" => %{"value" => v}}} -> IO.puts("BEHAVIOR_RESULT FAIL (still has value: " <> inspect(v) <> ")")
  other -> IO.puts("BEHAVIOR_RESULT ERR " <> inspect(other))
end
'

# Probe D — IndexedDB cleared by Storage.clearDataForOrigin?
# Uses a Promise-yielding eval and waits via awaitPromise.
probe_behavior "IndexedDB cleared by Storage.clearDataForOrigin" '
# Open an IDB and write a row.
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "awaitPromise" => true,
  "expression" => """
  new Promise((res) => {
    const r = indexedDB.open("probe", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("s");
    r.onsuccess = () => {
      const tx = r.result.transaction("s", "readwrite");
      tx.objectStore("s").put("v", "k");
      tx.oncomplete = () => res(true);
    };
  })
  """
})
{:ok, _} = Wallabidi.WebSocket.send_sync(ws, "Storage.clearDataForOrigin", %{
  "sessionId" => sess,
  "origin" => "http://localhost:4321",
  "storageTypes" => "all"
})
result = Wallabidi.WebSocket.send_sync(ws, "Runtime.evaluate", %{
  "sessionId" => sess,
  "awaitPromise" => true,
  "returnByValue" => true,
  "expression" => """
  new Promise((res) => {
    const r = indexedDB.open("probe", 1);
    r.onupgradeneeded = () => res("recreated_empty");
    r.onsuccess = () => {
      const tx = r.result.transaction("s", "readonly");
      const g = tx.objectStore("s").get("k");
      g.onsuccess = () => res(g.result == null ? "empty" : "leftover:" + g.result);
      g.onerror = () => res("err");
    };
    r.onerror = () => res("open_err");
  })
  """
})
case result do
  {:ok, %{"result" => %{"value" => v}}} when v in ["empty", "recreated_empty"] -> IO.puts("BEHAVIOR_RESULT PASS")
  {:ok, %{"result" => %{"value" => v}}} -> IO.puts("BEHAVIOR_RESULT FAIL (got: " <> inspect(v) <> ")")
  other -> IO.puts("BEHAVIOR_RESULT ERR " <> inspect(other))
end
'

echo
echo "Done. Full log: $OUT"
