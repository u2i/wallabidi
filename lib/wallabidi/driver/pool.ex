defmodule Wallabidi.Driver.Pool do
  @moduledoc """
  Behaviour drivers implement to plug into `Wallabidi.Pool`.

  Each driver decides what a "slot" means. The pool is generic — it
  manages N slots, hands them out to test sessions, monitors callers,
  and reaps slots whose owner died. The driver provides the
  engine-specific lifecycle.

  ## Slot model

  - `open_slot/1` — called once per slot at pool startup (or on
    recovery). The driver returns a slot handle (any term it needs to
    track resources: WebSocket pid, browser context id, etc.). For
    chromium-bidi this is "open a WebSocket → server spawns Chrome";
    for ChromeCDP it's "use the singleton CDP connection."

  - `close_slot/1` — at pool shutdown or slot retirement. Tear down
    whatever `open_slot/1` brought up.

  - `prepare_session/2` — called at checkout to set up per-test state
    on the slot (e.g. create a fresh BiDi userContext + browsingContext).
    Returns a session-specific state the caller will pass back to
    `finalize_session/2`.

  - `finalize_session/2` — called at checkin to tear down per-test
    state without disturbing the slot. The slot stays alive for the
    next session.

  - `reset_slot/1` — optional housekeeping between sessions on the
    same slot. Returns `:ok` if the slot is reusable, `:must_recreate`
    if the pool should drop and re-open it.

  ## Why not just one callback?

  Splitting open/close from prepare/finalize lets the pool keep slots
  warm across many sessions. Per-slot setup (Chrome boot, WebSocket
  upgrade) is expensive; per-session setup (BiDi userContext) is
  cheap. Doing the cheap part on each checkout, while reusing the
  expensive part, is what makes pooling pay off.
  """

  @type slot_handle :: term()
  @type session_state :: term()
  @type opts :: keyword()

  @doc """
  Bring up one pool slot. Called once per slot at pool startup.

  Returns `{:ok, slot_handle}` on success. The handle is opaque to
  the pool — it's whatever the driver needs to identify and operate
  on the slot's resources. Failures should return `{:error, reason}`;
  the pool will retry or surface to start_link callers.
  """
  @callback open_slot(opts) :: {:ok, slot_handle} | {:error, term}

  @doc """
  Tear down a slot. Called when the pool shuts down or when
  `reset_slot/1` returned `:must_recreate`.
  """
  @callback close_slot(slot_handle) :: :ok

  @doc """
  Set up per-test session state on the slot. Runs at checkout.

  Returns `{:ok, session_state}` where `session_state` carries
  everything `finalize_session/2` will need to clean up.
  """
  @callback prepare_session(slot_handle, opts) ::
              {:ok, session_state} | {:error, term}

  @doc """
  Tear down per-test state. Runs at checkin. Must not raise; the
  pool calls this even when the test crashed mid-session, so it has
  to handle partially-set-up state gracefully.
  """
  @callback finalize_session(slot_handle, session_state) :: :ok

  @doc """
  Optional housekeeping between sessions on the same slot. Default
  implementation is a no-op. Return `:must_recreate` if the slot is
  in a bad state and should be torn down + reopened (e.g. WebSocket
  closed, Chrome crashed).
  """
  @callback reset_slot(slot_handle) :: :ok | :must_recreate

  @optional_callbacks reset_slot: 1
end
