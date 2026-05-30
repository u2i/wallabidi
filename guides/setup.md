# Setup

Requires Elixir 1.19+, OTP 28+. Use `mix wallabidi.install` to download the browsers the drivers need (Chrome for Testing, Lightpanda, and the chromium-bidi Node deps) into `.browsers/`, or point the `WALLABIDI_*_PATH` env vars at existing binaries.

## Installation

```elixir
def deps do
  [{:wallabidi, "~> 0.4.0-rc", runtime: false, only: :test}]
end
```

```elixir
# test/test_helper.exs
{:ok, _} = Application.ensure_all_started(:wallabidi)
```

## How browsers are managed

Wallabidi launches browsers directly — no chromedriver, Selenium server, or Docker container in the loop. `mix wallabidi.install` downloads everything the drivers need (Chrome for Testing, Lightpanda, and the chromium-bidi Node deps) into a single project-local `.browsers/` directory:

```
$ MIX_ENV=test mix wallabidi.install   # Chrome + Lightpanda + chromium-bidi → .browsers/
$ mix test
```

> `MIX_ENV=test` is required when wallabidi is in your `deps` as
> `only: :test` (the typical setup) — Mix only loads the task module
> in environments where wallabidi compiles. Plain `mix
> wallabidi.install` raises `task could not be found`.

Both browsers land in version-stamped subdirectories so multiple
versions coexist, and the resolved binary paths are recorded in
`.browsers/PATHS`:

```
.browsers/
  PATHS                                              # CHROME=… and LIGHTPANDA=…
  chrome/mac_arm-149.0.7827.54/…
  lightpanda/aarch64-macos-fork-2026-05-30/lightpanda-…
```

### Chrome

If Chrome is on your PATH or has been installed by `mix wallabidi.install`, Wallabidi launches it directly via CDP. Override the binary path with `WALLABIDI_CHROME_PATH` if Chrome lives somewhere unusual:

```bash
WALLABIDI_CHROME_PATH=/usr/bin/google-chrome-stable mix test
```

When Chrome runs as a service in a Docker Compose stack, point Wallabidi at it with `WALLABIDI_CHROME_URL` (see [Remote Chrome](#remote-chrome-ci-docker) below).

### Lightpanda

The Lightpanda binary is provided by the [`lightpanda`](https://hex.pm/packages/lightpanda) dependency (the release tag is baked into that dep — bump it to upgrade). `mix wallabidi.install` downloads it into `.browsers/lightpanda/` alongside Chrome. Override the binary path with `WALLABIDI_LIGHTPANDA_PATH` for Docker/CI images that already ship Lightpanda:

```bash
WALLABIDI_LIGHTPANDA_PATH=/opt/lightpanda/lightpanda mix test
```

If you don't run `mix wallabidi.install`, the `lightpanda` package falls back to downloading into `_build/` on first use.

### Remote Chrome (CI / Docker)

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
- run: MIX_ENV=test mix wallabidi.install   # Chrome + Lightpanda + chromium-bidi → .browsers/
- run: mix test
```

`mix wallabidi.install` uses `npx @puppeteer/browsers install` to download
a pinned Chrome for Testing binary, plus the Lightpanda binary, into
`.browsers/`. To install just one browser, use `mix wallabidi.install.chrome`
or `mix wallabidi.install.lightpanda`. Cache the directory for faster
subsequent runs:

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
| `WALLABIDI_LIGHTPANDA_PATH` | Local Lightpanda binary override | `/opt/lightpanda/lightpanda` |

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
