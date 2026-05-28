# Test Isolation (Ecto, Mimic, Mox, Cachex, FunWithFlags)

Browser tests need sandbox access propagated to every server-side process the browser triggers (Plug requests, LiveView mounts, async tasks). Wallabidi integrates with [`sandbox_case`](https://github.com/pinetops/sandbox_case) and [`sandbox_shim`](https://github.com/pinetops/sandbox_shim) to handle this automatically.

`sandbox_case` manages checkout/checkin of all sandbox adapters (Ecto, Cachex, FunWithFlags, Mimic, Mox) from a single config. `sandbox_shim` provides compile-time macros that wire the sandbox plugs and hooks into your endpoint and LiveViews — emitting nothing in production.

```elixir
# mix.exs
{:sandbox_shim, "~> 0.1"},                                    # all envs (compile-time only)
{:sandbox_case, "~> 0.3", only: :test},                       # test only
{:wallabidi, "~> 0.4.0-rc", only: :test, runtime: false},           # test only
```

```elixir
# config/test.exs
config :sandbox_case,
  otp_app: :your_app,
  sandbox: [
    ecto: true,
    cachex: [:my_cache],            # optional
    fun_with_flags: true,           # optional
    mimic: true,                    # auto-discovers Mimic.copy'd modules
    mox: [MyApp.MockWeather]        # optional
  ]
```

```elixir
# lib/your_app_web/endpoint.ex
import SandboxShim
sandbox_plugs()

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
    # auth hooks after
  end
end
```

```elixir
# test/test_helper.exs
SandboxCase.Sandbox.setup()
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

With `use Wallabidi.Feature`, sandbox checkout/checkin is automatic — no manual `Ecto.Adapters.SQL.Sandbox.checkout` calls needed.
