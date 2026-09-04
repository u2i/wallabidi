# Recording a session

Wallabidi has no video-recording feature of its own — there's no CDP domain
for it, and no in-browser recording API this guide relies on. What follows
is a recipe for recording the whole browser window (page content plus
Chrome's own UI) around a session Wallabidi drives, using tooling external
to the browser entirely. The approach, and the gotchas below (autoplay
policy, headless Chrome's X11 dependency, teardown ordering), came from
building a real capture against a live YouTube video, not from
documentation.

## Why not getDisplayMedia?

Chrome's own in-page tab-capture API (`getDisplayMedia` + `MediaRecorder`)
is the obvious first thing to reach for, and it doesn't work headless.
Concretely, across `chromedp/headless-shell`, a pre-release Chrome for
Testing arm64 build, and Debian's packaged Chromium:

- `--headless=new` has no window-manager/picker surface at all —
  `getDisplayMedia` either hangs indefinitely awaiting a promise that never
  resolves (surfacing as CDP's `"Promise was collected"` if you try to
  `awaitPromise` across it) or fails outright.
- The underlying Linux desktop-capture backend
  (`third_party/webrtc/modules/desktop_capture/linux/x11/...`) needs a real
  X11 display. Headless Chrome has none, so tab/desktop capture fails with
  `NotReadableError` regardless of flags — `--auto-select-desktop-capture-source`,
  `--use-fake-ui-for-media-stream`, none of it helps, because the failure is
  before the picker: there's no display for the capture backend to attach to.

Once Chrome runs against a **real** (virtual) X11 display, this stops being
a browser problem — capture the display directly and skip `getDisplayMedia`
entirely.

## The recipe: Xvfb + ffmpeg

Run Chrome **not headless**, against a virtual framebuffer, and record that
framebuffer with `ffmpeg`. Chrome never knows it's being recorded — no
picker, no permission prompt, no `getDisplayMedia` call anywhere.

### Container setup

```dockerfile
FROM debian:trixie-slim

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
       chromium socat xvfb fluxbox ffmpeg \
       pulseaudio pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

`fluxbox` matters — a bare Xvfb has no window manager, and Chrome's own
window/tab handling behaves unreliably without one.

```sh
#!/bin/sh
set -e

# Virtual audio sink — headless Chrome has no real sound device, and
# without one, playing audio raises NotReadableError inside the page.
export PULSE_SERVER=unix:/tmp/pulse-native
pulseaudio -D --exit-idle-time=-1 --disallow-exit --log-target=stderr \
  --load="module-native-protocol-unix socket=/tmp/pulse-native"
for i in $(seq 1 20); do pactl info >/dev/null 2>&1 && break; sleep 0.2; done
pactl load-module module-null-sink sink_name=virtual_speaker \
  sink_properties=device.description=Virtual_Speaker
pactl set-default-sink virtual_speaker

# Virtual display, sized a bit larger than the browser window so
# Chrome's own chrome (tab bar, address bar) isn't clipped by the
# capture region — see "Sizing" below.
export DISPLAY=:99
Xvfb :99 -screen 0 1280x960x24 -nolisten tcp &
sleep 1
fluxbox >/tmp/fluxbox.log 2>&1 &
sleep 1

# Chrome only ever binds its DevTools port to loopback inside the
# container, regardless of --remote-debugging-address — relay the
# externally-exposed port to it.
socat TCP4-LISTEN:9222,fork,reuseaddr TCP4:127.0.0.1:9223 &

# NOT --headless: tab/window capture needs a real X11 display, which
# headless mode doesn't provide at all, at any Chrome version.
exec chromium --no-sandbox --remote-debugging-port=9223 "$@"
```

Connect Wallabidi to this Chrome the normal way:

```elixir
# WALLABIDI_CHROME_URL points at the socat-relayed port (or localhost:9222
# directly, if Wallabidi runs in the same container as Chrome — see FLAME
# below).
{:ok, session} = Wallabidi.start_session(driver: :chrome_cdp)
```

### Sizing

`chromium --window-size=1280,960` and Xvfb's `1280x960` screen should match.
If the display is only as big as the page's viewport, Chrome's own UI
(which sits on top of the viewport, not inside it) gets clipped by the
capture region — you'll see the top of the tab bar and nothing else.
Leaving headroom (viewport height + ~160px for tab bar / address bar / any
infobar) fixes this; make the Xvfb screen and the `ffmpeg` capture
`-video_size` match that larger size, not the browser's own window-size.

### Capturing

```sh
DISPLAY=:99 PULSE_SERVER=unix:/tmp/pulse-native ffmpeg -y \
  -f x11grab -video_size 1280x960 -framerate 25 -i :99 \
  -f pulse -i virtual_speaker.monitor \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac \
  /tmp/recording.mp4
```

`-video_size` must match the Xvfb screen size exactly. `-framerate` is a
straightforward tradeoff — 25 is a reasonable default; lower it (10–15) for
smaller files when smooth motion doesn't matter, raise it (30+) if it does,
at the cost of more CPU spent encoding.

Drive this from Elixir as a `Port` (or `System.cmd/3` with `into:` for
streaming output) alongside the Wallabidi session:

```elixir
{:ok, session} = Wallabidi.start_session(driver: :chrome_cdp)
Wallabidi.Browser.visit(session, url)

ffmpeg_port =
  Port.open({:spawn_executable, System.find_executable("ffmpeg")},
    args: ~w(-y -f x11grab -video_size 1280x960 -framerate 25 -i :99
              -f pulse -i virtual_speaker.monitor
              -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac
              /tmp/recording.mp4),
    env: [{~c"DISPLAY", ~c":99"}, {~c"PULSE_SERVER", ~c"unix:/tmp/pulse-native"}]
  )

# ... let the session run for the duration you want recorded ...

Port.command(ffmpeg_port, "q")  # ffmpeg's own graceful-stop input
```

### Autoplay needs a real click

Headless-adjacent Chrome (this is not headless, but launched by automation
without any prior user interaction) still enforces autoplay policy: calling
`video.play()` with sound un-muted from `execute_script` raises
`NotAllowedError` — *"play() failed because the user didn't interact with
the document first"*. Muting defeats the purpose of recording audio.

The fix is a **real** CDP-dispatched input event, which counts as a genuine
user gesture the way a JS call alone doesn't:

```elixir
Wallabidi.Remote.CDP.Client.click_at_cursor(session, :left)
Process.sleep(500)

Wallabidi.Browser.execute_script(session, """
  const video = document.querySelector("video");
  video.muted = false;
  video.play();
""")
```

### Stop the recording before the session, not after

`Wallabidi.end_session/1` closes the browser target. If `ffmpeg` is still
capturing when that happens, the tail of the recording catches Chrome
falling back to a default page mid-capture — in this build, that showed up
as a plain search page appearing at the very end of an otherwise-correct
recording, with Chrome's own `--no-sandbox` infobar reappearing alongside it
(a reliable sign of a fresh top-level navigation, not a crash). Stop
`ffmpeg` and let it flush before tearing down the session:

```elixir
stop_ffmpeg(ffmpeg_port)
# ffmpeg has exited and finalized the file — safe to tear down now.
Wallabidi.end_session(session)
```

## Running this on Fly with FLAME

A recording session is a single unit of work with a clear start and end —
join, record, upload, done — which maps well onto
[FLAME](https://hexdocs.pm/flame)'s per-call ephemeral Machine model rather
than a long-lived pool.

**The image above becomes your app's own `Dockerfile`.** FLAME runs your
Phoenix app's release inside the Machine it creates, so the
Xvfb/PulseAudio/Chrome bring-up needs to happen as part of that same
image's entrypoint, before (or wrapping) your release start — not as a
separate sidecar container.

**Wallabidi and Chrome share one Machine**, so `WALLABIDI_CHROME_URL` points
at `localhost:9222` directly — no cross-container networking, no `socat`
relay needed once both live in the same Machine (the relay above was purely
a local-Docker-Desktop workaround for reaching a container's loopback-bound
port from the host).

**The FLAME-executed function does the whole job:**

```elixir
FLAME.call(MyApp.RecordingRunner, fn ->
  {:ok, session} = Wallabidi.start_session(driver: :chrome_cdp)
  Wallabidi.Browser.visit(session, url)

  # ... whatever the target page needs to start playing/recording ...

  ffmpeg_port = start_ffmpeg_capture(output_path)

  # ... hold the Machine open for the duration you want recorded ...

  stop_ffmpeg_capture(ffmpeg_port)
  Wallabidi.end_session(session)

  upload_to_s3(output_path)
end)
```

**Sizing**: Chrome plus software-rendered X11 compositing plus `ffmpeg`
encoding is real CPU work — 2 shared vCPUs / 2GB is a reasonable starting
point for `fly.toml`'s Machine spec, not the smallest available size.

**Idle timeout**: this is long-running work inside a single `FLAME.call`,
not a burst of short requests — make sure FLAME's idle-shutdown timeout (or
your `FLAME.Pool` config, if using one instead of `FLAME.call` directly)
doesn't reclaim the Machine mid-recording.

## What Wallabidi doesn't do here

To be explicit about the boundary: Wallabidi drives navigation and page
interaction. It does not manage `ffmpeg`, does not know a recording is
happening, and has no API for it — every piece above (Xvfb, PulseAudio,
`ffmpeg`, the FLAME wiring) is infrastructure the host app owns.
