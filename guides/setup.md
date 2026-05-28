# Setup

Requires Elixir 1.19+, OTP 28+, and Chrome (or Chromium). Use `mix wallabidi.install` to download a pinned Chrome for Testing build, or set `WALLABIDI_CHROME_PATH` to your existing Chrome binary.

## Installation

```elixir
def deps do
  [{:wallabidi, "~> 0.2", runtime: false, only: :test}]
end
```

```elixir
# test/test_helper.exs
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

## How Chrome is managed

Wallabidi launches Chrome directly — no chromedriver, Selenium server, or Docker container in the loop. There are two modes:

### 1. Local Chrome (default)

If Chrome is on your PATH or has been installed by `mix wallabidi.install`, Wallabidi launches it directly via CDP.

```
$ mix wallabidi.install  # downloads Chrome for Testing into .browsers/
$ mix test
```

Override the binary path with `WALLABIDI_CHROME_PATH` if Chrome lives somewhere unusual:

```bash
WALLABIDI_CHROME_PATH=/usr/bin/google-chrome-stable mix test
```

### 2. Remote Chrome (CI / Docker)

When Chrome runs as a service in your Docker Compose stack, point Wallabidi at it:

```bash
# .env or CI config — just the host:port, wallabidi handles the rest
WALLABIDI_CHROME_URL=chrome:9222
```

Wallabidi auto-discovers the WebSocket URL via `/json/version`. Full `ws://` URLs also work for backward compat.

## CI (GitHub Actions)

```yaml
steps:
- uses: actions/checkout@v6
- uses: erlef/setup-beam@v1
  with:
    otp-version: 28.x
    elixir-version: 1.19.x
- uses: actions/setup-node@v4
  with:
    node-version: 20

- run: mix deps.get
- run: mix wallabidi.install   # downloads Chrome for Testing
- run: mix test
```

`mix wallabidi.install` uses `npx @puppeteer/browsers install` to download
a pinned Chrome for Testing binary into `.browsers/`. Cache this directory
for faster subsequent runs:

```yaml
- uses: actions/cache@v5
  with:
    path: .browsers
    key: ${{ runner.os }}-browsers-${{ hashFiles('.browsers/PATHS') }}
    restore-keys: ${{ runner.os }}-browsers-
```

### Environment variable overrides

For Docker-based CI or remote browsers:

| Variable | Purpose | Example |
|----------|---------|---------|
| `WALLABIDI_CHROME_URL` | Connect to remote Chrome (CDP) | `chrome:9222` |
| `WALLABIDI_CHROME_PATH` | Local Chrome binary override | `/usr/bin/google-chrome` |

If you have Chrome pre-installed on the runner (e.g. GitHub Actions' built-in
Chrome), set `WALLABIDI_CHROME_PATH` and skip `mix wallabidi.install`:

```yaml
- run: mix test
  env:
    WALLABIDI_CHROME_PATH: /usr/bin/google-chrome-stable
```

## Phoenix

```elixir
# config/test.exs
config :your_app, YourAppWeb.Endpoint, server: true

# test/test_helper.exs
Application.put_env(:wallabidi, :base_url, YourAppWeb.Endpoint.url)
```

## Test isolation

Browser tests need sandbox access propagated to every server-side process the
browser triggers (Ecto, Mimic, Mox, Cachex, FunWithFlags). See the
[Test Isolation guide](isolation.html) for the full `sandbox_case` /
`sandbox_shim` setup.
