// Wallabidi BiDi server runner.
//
// Spawns the chromium-bidi WebSocket server on the requested PORT, with the
// Chrome binary at BROWSER_BIN. Logs "Listening on port=NNNN" on stderr once
// the server is accepting connections so the BEAM-side launcher knows when
// it's safe to connect.
//
// Environment:
//   PORT=8080              — TCP port to bind (default 8080; pass 0 for ephemeral)
//   BROWSER_BIN=/path      — Chrome/Chromium binary path
//   HEADLESS=true|false    — passed through to chromium-bidi
//   VERBOSE=true|false     — passed through to chromium-bidi for debug logging

import {WebSocketServer, debugInfo} from 'chromium-bidi/bidiServer/WebSocketServer.js';

// Surface unhandled errors instead of dying silently. When chromium-bidi's
// Mapper or one of its child Chrome connections throws an async error
// without a catch, Node 20 exits with status 1 and no log line. The
// BEAM-side launcher then sees just "exit_status=1, buffer=''" which is
// useless for debugging. These handlers print the reason to stderr first.
process.on('unhandledRejection', (reason) => {
  process.stderr.write(`wallabidi-bidi-server: unhandledRejection: ${reason?.stack || reason}\n`);
});
process.on('uncaughtException', (err) => {
  process.stderr.write(`wallabidi-bidi-server: uncaughtException: ${err?.stack || err}\n`);
});

const port = process.env.PORT ? Number(process.env.PORT) : 8080;
const verbose = process.env.VERBOSE === 'true';

debugInfo(`Launching Wallabidi BiDi server on port ${port}...`);

const server = new WebSocketServer(port, verbose);

// chromium-bidi's WebSocketServer logs its own readiness; we mirror it on
// stderr so the BEAM-side launcher can synchronize on a known string.
process.stderr.write(`wallabidi-bidi-server: ready on port=${port}\n`);
