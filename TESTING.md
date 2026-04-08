# Testing

## Structure

```
test/                         Unit tests (no browser)
integration_test/cases/       Integration tests (all drivers)
bench/                        Load tests + benchmarks
```

## Drivers

| Driver | Protocol | Speed | What it tests |
|--------|----------|-------|---------------|
| `chrome_cdp` | CDP direct to Chrome | Fast (1ms/op) | Full browser behavior |
| `chrome` | WebDriver BiDi via chromedriver | Medium (10-60ms/op) | BiDi protocol path |
| `live_view` | Phoenix channels (no browser) | Fastest (0.1ms/op) | LiveView routes only |

## Running tests

```bash
# Unit tests
mix test

# Integration tests (pick a driver)
mix test.chrome            # Chrome via CDP (default, recommended)
mix test.chrome.bidi       # Chrome via WebDriver BiDi
mix test.live_view         # LiveView driver (no browser needed)

# All drivers sequentially
mix test.all

# Benchmarks and load tests
mix test.bench

# Lifecycle tests (subprocess isolation)
mix test.chrome.lifecycle

# Run a specific test file
WALLABIDI_DRIVER=chrome_cdp mix test integration_test/cases/browser/find_test.exs --no-start

# Run with low concurrency (avoids Chrome process exhaustion)
WALLABIDI_DRIVER=chrome_cdp mix test --no-start --max-cases 2
```

## Tags

Tests use tags to declare what infrastructure they need:

| Tag | Meaning | Runs on |
|-----|---------|---------|
| `@moduletag :browser` | Needs a real Chrome browser | CDP, BiDi |
| `@moduletag :headless` | Needs headless browser | CDP, BiDi, Lightpanda |
| `@moduletag :live_view_only` | Only runs on LiveView driver | LiveView |
| `@tag :pending` | Not yet implemented | Nothing (excluded) |

Tests without tags run on all drivers.

## Test organization

### `integration_test/cases/browser/`
Shared tests that run on every driver. Most tests live here. They use
`SessionCase` which creates a session and visits a page automatically.

### `integration_test/cases/chrome/`
Chrome-specific tests (tagged `@moduletag :browser`): push-based finding,
shared connection, LiveView await/patch, capabilities.

### `integration_test/cases/live_view/`
LiveView-only tests (tagged `@moduletag :live_view_only`): feature macro
routing verification.

### `bench/`
Not run in CI. Load tests verify throughput under concurrent sessions.
Timing benchmarks compare per-operation latency across drivers.

## Writing tests

Use `SessionCase` for most tests:

```elixir
defmodule MyTest do
  use Wallabidi.Integration.SessionCase, async: true

  test "find an element", %{session: session} do
    session
    |> visit("page_1.html")
    |> find(Query.css("h1"))
  end
end
```

For tests that need Chrome, add `@moduletag :browser`.
For LiveView-only tests, add `@moduletag :live_view_only`.

## Debugging

```bash
# Run one test with verbose output
WALLABIDI_DRIVER=chrome_cdp mix test integration_test/cases/browser/click_test.exs:54 \
  --no-start --max-cases 1 --timeout 60000

# Per-operation timing benchmark (2>/dev/null suppresses Chrome's stderr noise)
mix test.bench 2>/dev/null

# Kill zombie Chrome processes
pkill -9 -f "Google Chrome for Testing"; pkill -9 -f chromedriver
```
