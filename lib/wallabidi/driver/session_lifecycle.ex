defmodule Wallabidi.Driver.SessionLifecycle do
  @moduledoc false

  alias Wallabidi.BiDi.WebSocketClient
  alias Wallabidi.Session

  # Shared session lifecycle helpers for all drivers.
  #
  # ## The problem
  #
  # Wallabidi tests spawn long-lived resources (WebSockets, chromedriver
  # sessions, browser processes) from within test processes. When a test
  # finishes, cleanup runs in an `on_exit` callback — which ExUnit runs in
  # a separate process AFTER the test process has exited.
  #
  # If a resource is linked to the test process (via `start_link`), it dies
  # with the test process, and cleanup in `on_exit` will fail with `:exit`
  # errors (`:shutdown`, `:noproc`, `:normal`) when trying to use the dead
  # resource.
  #
  # ## The pattern
  #
  # 1. **Unlink** — after starting a linked resource inside a test process,
  #    unlink it so it survives the test process exiting. Cleanup will run
  #    it down explicitly.
  #
  # 2. **Safe cleanup** — wrap cleanup calls in both `rescue` (for exceptions)
  #    AND `catch :exit, _` (for process exits). `rescue` does NOT catch
  #    exits, so a dead GenServer bubbles through `rescue _ -> :ok`.
  #
  # 3. **Idempotent** — cleanup may run twice (once explicitly, once via
  #    SessionStore monitor). Each step must be safe to call on already-dead
  #    resources.

  @doc """
  Detaches a linked process from the current process. The detached process
  will survive the current process exiting — useful for resources created
  in tests that must be cleaned up later in `on_exit`.

  Returns `pid` unchanged for convenient piping.
  """
  @spec detach(pid) :: pid
  def detach(pid) when is_pid(pid) do
    Process.unlink(pid)
    pid
  catch
    :error, :badarg -> pid
  end

  @doc """
  Runs a cleanup function, swallowing any exceptions or process exits.

  Use for driver cleanup calls that may hit dead resources (dead WebSockets,
  closed HTTP connections, exited GenServers). Returns `:ok`.

  ## Example

      def end_session(session) do
        SessionLifecycle.safe(fn -> close_websocket(session) end)
        SessionLifecycle.safe(fn -> delete_chromedriver_session(session) end)
        :ok
      end
  """
  @spec safe((-> any)) :: :ok
  def safe(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Like `safe/1`, but skips invocation entirely if `resource` is `nil`.

  Drivers often carry optional resources on the session struct
  (e.g. `bidi_pid`) that may be `nil` when start_session failed
  partway or when the driver doesn't use that resource. This helper
  bundles the nil check with the safe cleanup.

  ## Example

      def end_session(session) do
        SessionLifecycle.safe(fn -> delete_http_session(session) end)
        SessionLifecycle.safe(session.bidi_pid, &WebSocketClient.close/1)
        :ok
      end
  """
  @spec safe(any, (any -> any)) :: :ok
  def safe(nil, _fun), do: :ok

  def safe(resource, fun) when is_function(fun, 1) do
    safe(fn -> fun.(resource) end)
  end

  @doc """
  Tears down a session in the standard order:

  1. **Release server-side state** — calls the driver's optional
     `release_server_session/1` callback (if defined) to tell the server
     to drop the session. For Chrome BiDi this is an HTTP DELETE; for
     Chrome CDP it's `Target.disposeBrowserContext`; Lightpanda doesn't
     implement it (disconnect is cleanup).

  2. **Close the transport** — the WebSocket at `session.bidi_pid`. This
     is common to all drivers and always runs last.

  Each step is wrapped in `safe/1` so a failure in one step doesn't
  prevent the other from running. This is the standard implementation
  of `Driver.end_session/1`.
  """
  @spec teardown(Session.t()) :: :ok
  def teardown(%Session{driver: driver} = session) do
    if Code.ensure_loaded?(driver) and function_exported?(driver, :release_server_session, 1) do
      safe(fn -> driver.release_server_session(session) end)
    end

    safe(session.bidi_pid, &WebSocketClient.close/1)
    :ok
  end
end
