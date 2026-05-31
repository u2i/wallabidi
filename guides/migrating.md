# Migrating from Wallaby

Wallabidi is a fork of [Wallaby](https://github.com/elixir-wallaby/wallaby) with a
public API close to Wallaby's for easy migration. The `Browser`, `Query`, `Element`,
`Feature`, and `DSL` APIs are the same.

## What's different from Wallaby?

**Protocol**: Browser communication goes over WebSocket — Chrome via CDP or BiDi, Lightpanda via CDP — never HTTP polling. This means event-driven log capture, lower latency, and access to features impossible with request-response HTTP.

**LiveView-aware by default**: Every interaction automatically waits for the right thing — no manual sleeps or retry loops needed:

- `visit/2` waits for the LiveSocket to connect before returning.
- `click/2` inspects the target element's bindings (`phx-click`, `data-phx-link`, plain `href`) and classifies the interaction as patch, navigate, or full-page in the *same round-trip* as the click itself. It then awaits the corresponding DOM patch, page load, or LiveView reconnection automatically.
- `fill_in/3` on `phx-change` inputs fuses silent-clear + set-value + drain-patches into one round-trip — the call returns only once the server has finished processing the final phx-change.
- `assert_has/2` uses an event-driven `await_selector` that hooks into LiveView's `onPatchEnd` callback and a `MutationObserver` — it fires the next-match check exactly when the DOM changes, never polls.
- `has_text?/2`, `has_value?/2` route through the same event-driven pattern: a single Promise inside the browser resolves the moment the predicate matches, replacing Elixir-side polling loops.

All of this is installed via injected JavaScript — no changes to your `app.js` or LiveSocket config are needed.

**Architecture**: A single opcode interpreter (`W.run`) on the page side handles every Elixir → browser call. The Elixir side ships opcode lists like `[["query","css",".btn"],["classify_first","click"],["click_first"]]`, never raw JS function bodies. Compound operations (click_aware, fill_in, has_text) fuse multiple steps into a single Promise so each logical operation is one network round-trip. See the [Architecture guide](architecture.html) for the full picture.

**Lazy elements**: Most Browser APIs that find then immediately operate (`Browser.text`, `attr`, `fill_in`, `click`, `has_text?`...) skip the V8-object-id ref-fetch that Wallaby would do — the element op re-resolves the query inline on the page. Saves one round-trip per element op without changing semantics.

**New features**:
- `await_patch/2` — Wait for the next LiveView DOM patch. Useful for server-pushed updates that aren't triggered by a browser interaction.

**Four drivers**: LiveView (in-process, no browser), Lightpanda (headless CDP), Chrome CDP (full browser, direct DevTools Protocol), Chrome BiDi (full browser, W3C WebDriver BiDi via chromium-bidi). Tests declare their minimum requirement with `@tag :headless` or `@tag :browser`.

**Removed**:
- Selenium driver — replaced with native BiDi + CDP
- HTTPoison / Hackney dependencies — replaced with Mint
- `create_session_fn` / `end_session_fn` options

**Simplified**:
- Direct CDP/BiDi transport — no chromedriver process to manage
- Event-driven JS error detection (no HTTP polling per command)
- W3C capabilities format (`goog:chromeOptions`)

## Migration steps

1. Replace the dependency:

```elixir
# mix.exs
{:wallabidi, "~> 0.4.0-rc", runtime: false, only: :test}
```

2. Find and replace in your project:

| Wallaby | Wallabidi |
|---------|-----------|
| `Wallaby.` | `Wallabidi.` |
| `:wallaby` | `:wallabidi` |
| `config :wallaby,` | `config :wallabidi,` |

3. Remove if present:

```elixir
# No longer needed
config :wallaby, driver: Wallaby.Chrome
config :wallaby, hackney_options: [...]
```

4. **Pin the driver to `:chrome_cdp` to start.** Wallaby ran every test
   in a real Chrome; wallabidi instead routes by capability and defaults
   untagged tests to the in-process `:live_view` driver (see
   [Setup](setup.html) and the driver table in the README). Your existing
   Wallaby suite has no `@tag :headless` / `@tag :browser` tags, so
   without this every test would route to LiveView and fail. Keep the
   Wallaby behaviour first, then adopt tags incrementally:

   ```elixir
   # config/test.exs — preserves "everything runs in Chrome"
   config :wallabidi,
     otp_app: :your_app,
     endpoint: YourAppWeb.Endpoint,
     driver: :chrome_cdp
   ```

   Once you're green on Chrome, tag the tests that don't need a full
   browser (`@tag :headless` → Lightpanda, untagged → LiveView) to claw
   back the speed. You can drop the `driver: :chrome_cdp` line entirely
   when the suite is fully tagged and you want the cheapest-driver
   defaults.

5. That's it. The `Browser`, `Query`, `Element`, `Feature`, and `DSL` APIs are the same.
