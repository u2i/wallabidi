# Scraping

Wallabidi drives real browsers, and nothing about that is specific to
testing. If you need a JavaScript-executing browser to read a page — content
rendered client-side, behind a login, or assembled by a framework — you can
drive one from a plain script, a Mix task, or a GenServer.

Reading a page and asserting on a page are the same operation. The querying,
auto-waiting and navigation described here are what the test suite uses too;
only the surrounding code differs (`use Wallabidi.DSL` and
`Wallabidi.start_session/1` instead of `use Wallabidi.Feature`).

Everything in this guide works on any of the browser drivers — the API is
the same, and `status/1`, `response_headers/1` and `NavigationError` behave
identically across them. Only the trade-offs differ.

> If a plain HTTP request would do, use one. `Req` plus
> [`LazyHTML`](https://hex.pm/packages/lazy_html) is faster and simpler than
> any browser. Reach for Wallabidi when the content only exists after
> JavaScript runs.

## Choosing a driver

| | Lightpanda | Chrome (CDP) |
|---|---|---|
| Session start | ~70ms | ~1.1s |
| Page visit | ~20ms | ~160ms |
| User-Agent | `Lightpanda/1.0`, fixed | Real Chrome UA |
| `file://` URLs | ✗ | ✓ |
| Screenshots | ✗ | ✓ |
| iframes, dialogs, localStorage | ✗ | ✓ |
| CSS layout / visibility | ✗ | ✓ |

**Lightpanda** for volume: it's an order of magnitude cheaper per page, so
crawling many pages of a site you control (or one that doesn't care who's
asking) is much faster.

**Chrome** for fidelity: a real User-Agent, full CSS, and everything
Lightpanda's stripped-down engine leaves out. The fixed `Lightpanda/1.0`
User-Agent is the usual reason to switch — it's an obvious non-browser
signature, and sites that filter on it will serve different content or
block you outright.

Set it globally in config, or per session:

```elixir
config :wallabidi, driver: :chrome_cdp        # or :lightpanda

{:ok, session} = Wallabidi.start_session(driver: :chrome_cdp)
```

Chrome BiDi (`:chrome`) also works and supports the same API; CDP is the
faster of the two.

The rest of this guide uses Lightpanda in examples. Swap the driver and
everything else is unchanged.

## Setup

Add the dep **without** `only: :test` — the setup guide's snippet is
test-scoped because that's its context, but nothing about the driver is:

```elixir
# mix.exs
def deps do
  [
    {:wallabidi, "~> 0.4"},
    # only for the Lightpanda driver; Chrome needs no extra dep
    {:lightpanda, "~> 0.3.6"}
  ]
end
```

Then install the browser and point the app at the driver:

```bash
mix wallabidi.install            # Chrome + Lightpanda
```

```elixir
# config/config.exs
config :wallabidi, driver: :lightpanda   # or :chrome_cdp
```

Chrome is picked up off your PATH if it's already installed, so
`mix wallabidi.install` may skip the download entirely.

Setting `:driver` matters for more than defaults: it makes the supervisor
start that driver's shared browser process, so sessions multiplex over one
browser rather than each spawning its own.

## A first scrape

```elixir
use Wallabidi.DSL

{:ok, session} = Wallabidi.start_session()

visit(session, "https://example.com")

page_title(session)                    #=> "Example Domain"
text(session, Query.css("h1"))         #=> "Example Domain"
attr(session, Query.css("a"), "href")  #=> "https://iana.org/domains/example"

:ok = Wallabidi.end_session(session)
```

`use Wallabidi.DSL` imports `Wallabidi.Browser` and aliases `Wallabidi.Query`.
It has no ExUnit dependency — unlike `use Wallabidi.Feature`, which is for
tests.

Sessions clean themselves up when their owning process dies, so a crashed
scraper doesn't leak browser processes. `end_session/1` is still worth
calling on the happy path to free the connection immediately.

## Reading data out of a page

| Function | Returns |
|---|---|
| `page_source/1` | Full HTML of the current document |
| `page_title/1` | `<title>` text |
| `current_url/1` | URL after any redirects |
| `text/2` | Text of one matching element |
| `all/2` | List of all matching elements (`[]` when none) |
| `find/2` | One matching element (raises when absent) |
| `attr/3` | An attribute off a matched element |
| `Wallabidi.Element.text/1`, `Wallabidi.Element.attr/2` | Read from an element you already hold |
| `status/1`, `response_headers/1` | HTTP response metadata |
| `execute_script/3` | Run JS; the value arrives via callback |

Collecting a list:

```elixir
links =
  session
  |> all(Query.css("a"))
  |> Enum.map(&Wallabidi.Element.attr(&1, "href"))
```

Note `Wallabidi.Element.attr/2` takes an element, while `Browser.attr/3`
takes a query — easy to mix up.

`execute_script/3` returns the *session* so it can be piped; the script's
value is passed to a callback:

```elixir
execute_script(session, "return document.querySelectorAll('.item').length;", fn count ->
  IO.puts("#{count} items")
end)
```

## Auto-wait

Most read functions **retry until `:max_wait_time` (3s by default)** before
giving up. This is the feature that makes a browser worth the cost: content
that arrives after the initial HTML — a framework rendering, an XHR
resolving, a `setTimeout` firing — is waited for automatically, with no
polling loop of your own.

```elixir
visit(session, url)

# Blocks until the element appears, or 3s elapses. No sleep needed.
text(session, Query.css(".price"))
```

The cost is symmetrical: when an element is genuinely absent, you pay the
full wait before finding out. Measured against a page with no `.nope`
element (`max_wait_time` set to 3500ms here, hence the ~3.5s figures):

| Call | Cost on a miss |
|---|---|
| `text(session, Query.css(".nope"))` | **3507ms**, then raises |
| `has_css?(session, ".nope")` | **3502ms**, then `false` |
| `all(session, Query.css(".nope"))` | **51ms**, returns `[]` |

So the choice is about what a missing element *means* to you:

**Expected to be there** — use `text/2`, `find/2`, `has_css?/2`. The wait is
doing real work, and an absence is genuinely exceptional.

**Might legitimately be absent** — an optional badge, a field only some
records have — use `all/2` and match. It returns `[]` immediately instead of
waiting for something that was never coming:

```elixir
case all(session, Query.css(".price")) do
  [] -> nil
  [el | _] -> Wallabidi.Element.text(el)
end
```

Getting this wrong is the most common performance surprise in both tests and
scrapers: a suite or crawl that's mysteriously slow is usually paying a full
`max_wait_time` on every optional element.

Tune the budget to your pages — lower if content renders fast and you check
many optional selectors, higher for slow pages:

```elixir
config :wallabidi, max_wait_time: 500
```

## HTTP status

`visit/2` does not raise on an error status — a 404 or 500 loads like any
other page. Check the status when it matters:

```elixir
visit(session, url)

case status(session) do
  s when s in 200..299 -> scrape(session)
  404 -> :not_found
  s -> {:error, s}
end

response_headers(session)["content-type"]  #=> "text/html"
```

Headers come back as a map with lowercase string keys on every driver.

## Failed navigation raises

A navigation that fails outright — DNS failure, connection refused, an
unsupported URL scheme — raises `Wallabidi.NavigationError`:

```elixir
try do
  visit(session, url)
  {:ok, page_source(session)}
rescue
  e in Wallabidi.NavigationError -> {:error, Exception.message(e)}
end
```

This matters more than it looks. The browser stays on the previously loaded
page when navigation fails, so without the raise a loop over URLs would
silently record page N-1's content against page N.

## Concurrency

Sessions are independent and cheap, so `Task.async_stream/3` works well:

```elixir
urls
|> Task.async_stream(
  fn url ->
    {:ok, s} = Wallabidi.start_session()

    try do
      visit(s, url)
      {url, text(s, Query.css("h1"))}
    after
      Wallabidi.end_session(s)
    end
  end,
  max_concurrency: 16,
  timeout: 30_000
)
|> Enum.to_list()
```

**On Lightpanda, keep `max_concurrency` at 16 or below.** It's started with
`--cdp-max-connections 24`, and sessions beyond that limit fail rather than
queue. 16 leaves headroom; 8 concurrent sessions complete in ~150ms on a
laptop, so the cap is rarely the bottleneck. Chrome has no equivalent hard
cap, but each session costs far more memory — tune to your machine.

Be a good citizen on someone else's site: add delays, respect `robots.txt`,
and identify yourself where you can (though see the User-Agent note below).

## Lightpanda's limits

Both drivers execute JavaScript — `setTimeout` handlers, framework
rendering, `fetch` — which is the reason to use a browser at all. Chrome
supports everything below; Lightpanda trades these away for speed:

| Not supported on Lightpanda | Notes |
|---|---|
| Screenshots | `Page.captureScreenshot` isn't implemented |
| `file://` URLs | Raises `NavigationError` with `UnsupportedProtocol` — serve over HTTP instead |
| Custom User-Agent | Fixed at `Lightpanda/1.0`; `Network.setUserAgentOverride` is accepted and ignored |
| Custom request headers | `Network.setExtraHTTPHeaders` is accepted and ignored |
| iframes, dialogs, multi-window | Single browsing context only |
| Viewport resize | Accepted but has no effect (nothing is rendered) |
| localStorage | |
| CSS rendering | So layout-based visibility is unreliable — pass `visible: :any` |

Two of these fail *silently* rather than erroring: setting a User-Agent or
extra request headers returns `{:ok, %{}}` and then has no effect. Both are
upstream limitations in the Lightpanda binary, not in Wallabidi.

When you need any of these, switch that session to Chrome:

```elixir
{:ok, session} = Wallabidi.start_session(driver: :chrome_cdp)
```

Chrome supports the full set, at a higher per-page cost.

## Things that are not scraping problems

A couple of behaviours look alarming but aren't:

- **`visit/2` probes for LiveView on every navigation.** On a non-LiveView
  page this is a single `document.querySelector` that returns immediately —
  ~0.15ms against a ~22ms visit. It only waits when a page serves LiveView
  markup without a working `liveSocket`, which a third-party site won't do.

- **The `only: :test` dep in wallabidi's own mix.exs** is wallabidi's own
  test dependency. Declaring `{:lightpanda, "~> 0.3.6"}` in your project
  without `only: :test` puts it on the path in every environment; the driver
  checks availability at runtime, not compile time.
