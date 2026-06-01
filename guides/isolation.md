# Test Isolation (Ecto, Mimic, Mox, Cachex, FunWithFlags)

Browser tests need sandbox access propagated to every server-side process the browser triggers (Plug requests, LiveView mounts, async tasks). Wallabidi integrates with [`sandbox_case`](https://github.com/pinetops/sandbox_case) and [`sandbox_shim`](https://github.com/pinetops/sandbox_shim) to handle this automatically.

`sandbox_case` manages checkout/checkin of all sandbox adapters (Ecto, Cachex, FunWithFlags, Mimic, Mox) from a single config. `sandbox_shim` provides compile-time macros that wire the sandbox plugs and hooks into your endpoint and LiveViews — emitting nothing in production.

## Dependencies

`sandbox_case` and `sandbox_shim` themselves:

```elixir
# mix.exs
{:sandbox_shim, "~> 0.1"},                                  # all envs (compile-time only)
{:sandbox_case, "~> 0.4.0-rc", only: :test},                # test only
{:wallabidi, "~> 0.4.0-rc", only: :test, runtime: false},   # test only
```

> **Add a dep for every adapter you enable.** `sandbox_case` integrates
> with Mimic / Mox / Cachex / FunWithFlags but does **not** depend on
> them — and wallabidi's own copies of those packages are `only: :test`
> deps of *wallabidi*, so they are **not** pulled into your project
> transitively. Add the ones you turn on in the `sandbox:` config below,
> or `setup()` will compile fine and then fail at runtime the first time
> a test touches the adapter:
>
> ```elixir
> # mix.exs — only the adapters you actually enable
> {:mimic, "~> 1.7", only: :test},
> {:mox, "~> 1.2", only: :test},
> {:cachex, "~> 4.1", only: :test},
> {:fun_with_flags, "~> 1.11", only: :test},
> ```

## Configuration

```elixir
# config/test.exs
config :sandbox_case,
  otp_app: :your_app,
  sandbox: [
    ecto: true,                       # auto-discovers repos from otp_app
    cachex: [:my_cache],              # optional — see "Cachex" below
    fun_with_flags: true,             # optional — see "FunWithFlags" below
    mimic: [modules: [MyApp.Weather]],# optional — see "Mimic" below
    mox: [MyApp.MockWeather]          # optional — see "Mox" below
  ]
```

Enable only the adapters your suite uses. Each is described below — several need a line of setup beyond flipping the switch.

### Ecto

`ecto: true` auto-discovers the repos configured under your `otp_app` and checks each out per test. Your repos must already be configured for the SQL sandbox (the default in a generated Phoenix app):

```elixir
# config/test.exs
config :your_app, YourApp.Repo, pool: Ecto.Adapters.SQL.Sandbox
```

You can drop the generated `Ecto.Adapters.SQL.Sandbox.mode(YourApp.Repo, :manual)` line from `test_helper.exs` — `SandboxCase.Sandbox.setup()` (below) puts every repo into the right mode. The Phoenix-generated `DataCase` / `ConnCase` continue to work alongside `sandbox_case`; you don't need to remove them.

### Mimic

List the modules to stub explicitly:

```elixir
mimic: [modules: [MyApp.Weather]]
```

`sandbox_case` calls `Mimic.copy/1` on each listed module for you — you do **not** call `Mimic.copy` yourself. (The bare `mimic: true` form is *not* supported by current `sandbox_case`; always use the `[modules: [...]]` form.)

### Mox

List your mocks under `mox:`, and define them in `test_helper.exs` as usual:

```elixir
# config/test.exs
mox: [MyApp.MockWeather]
```

```elixir
# test/test_helper.exs — before SandboxCase.Sandbox.setup()
Mox.defmock(MyApp.MockWeather, for: MyApp.WeatherApi)
```

### Cachex

`cachex: [:my_cache]` isolates the named caches per test. You are still responsible for **starting** those caches in your supervision tree:

```elixir
# lib/your_app/application.ex
children = [
  # ...
  {Cachex, name: :my_cache}
]
```

If `cachex` is a `only: :test` dep, guard the child spec so dev/prod don't reference a missing module (e.g. only add it when `Code.ensure_loaded?(Cachex)`).

### FunWithFlags

`fun_with_flags: true` isolates flag state per test. Requires `sandbox_case ~> 0.4.0-rc` (earlier versions used a different, bytecode-based mechanism). FunWithFlags is **not** turnkey — three things to configure:

**1. A persistence backend (all envs).** By default FWF starts a Redis backend and crashes your app's boot if Redis isn't configured. Point it at one — the Ecto backend is simplest for a Phoenix app:

```elixir
# config/config.exs (dev/prod use the real adapter directly)
config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: YourApp.Repo
```

Then run FWF's Ecto migration (copy it from `deps/fun_with_flags/priv/ecto_repo/migrations/` and adapt the column types to your database — the template is Postgres-flavored). See the [FunWithFlags docs](https://hexdocs.pm/fun_with_flags) for other backends.

**2. The sandbox persistence adapter (`:test`).** `sandbox_case` isolates FunWithFlags through a custom persistence adapter — there is no bytecode patching. In the test env, wrap your real adapter with `SandboxCase.Sandbox.FwfAdapter`:

```elixir
# config/test.exs
config :fun_with_flags, :persistence,
  adapter: SandboxCase.Sandbox.FwfAdapter,
  sandbox_real_adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: YourApp.Repo
```

The adapter routes to a per-test isolated ETS table when a test is sandboxed, and delegates to `sandbox_real_adapter` otherwise. (`SandboxCase.Sandbox.setup/1` validates this wiring and raises with guidance if it's missing.)

**3. The cache, disabled in `:test`.**

```elixir
# config/test.exs
config :fun_with_flags, :cache, enabled: false
```

> FunWithFlags puts a single global ETS read-cache in front of its store.
> With the cache on, one test's flag value can be served to another
> concurrent test straight from that shared cache — bypassing the sandbox
> — so isolation leaks even when everything else is wired correctly.
> Disabling it routes every lookup through the (sandboxed) adapter. This
> must be set at compile time (in `config/test.exs`); FWF picks its store
> module at compile time. Disabling the cache also makes the Redis
> cache-bust-notifier boot crash impossible, so you don't need a separate
> `config :fun_with_flags, :cache_bust_notifications, enabled: false`.

## Wiring sandbox_shim into your app

```elixir
# lib/your_app_web/endpoint.ex — near the top of the module
import SandboxShim
sandbox_plugs()

# replace your existing `socket "/live", ...` with:
sandbox_socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]]
```

```elixir
# lib/your_app_web.ex
def live_view do
  quote do
    use Phoenix.LiveView
    import SandboxShim
    sandbox_on_mount()
    # your auth/other on_mount hooks after
  end
end
```

```elixir
# test/test_helper.exs
Mox.defmock(MyApp.MockWeather, for: MyApp.WeatherApi)  # if using Mox
SandboxCase.Sandbox.setup()
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

With `use Wallabidi.Feature`, sandbox checkout/checkin is automatic — no manual `Ecto.Adapters.SQL.Sandbox.checkout` calls needed. The sandbox owner is propagated to the browser-driven server processes via the request User-Agent on every remote driver (Chrome CDP, Chrome BiDi, Lightpanda); the in-process LiveView driver shares the test process directly.
