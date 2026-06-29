defmodule Wallabidi.Remote.Transport.Protocol do
  @moduledoc false

  # Documents the message protocol every transport-actor honors, and
  # provides thin client helpers that wrap the corresponding
  # `GenServer.call`/`GenServer.cast`. Callers (today: CDPClient,
  # Browser through dispatch) go through this module instead of
  # talking to Session directly — that lets us swap the actor
  # underneath each session for a different transport implementation
  #
  # ## Why a "protocol" and not a `@behaviour`
  #
  # A behaviour would force every transport to expose a module with
  # the same function arity, even though the only place we'd dispatch
  # to "the behaviour" is inside this client helper. A documented
  # message protocol is the same contract with one less indirection.
  #
  # ## Messages
  #
  # The session struct's `pid` is the transport actor. Every
  # transport actor must respond to:
  #
  # ### Synchronous (`GenServer.call`)
  #
  #   * `:get_session` → returns the `%Wallabidi.Session{}`.
  #   * `{:cdp_send, method, params, opts}` → runs a CDP RPC,
  #     returns `{:ok, term}` or `{:error, term}`.
  #   * `{:subscribe, event_method, routing_key}` → wires the actor
  #     to receive events of `event_method` matching `routing_key`.
  #     Returns `:ok`.
  #   * `{:await_page_load, loader_id, name, timeout_ms}` → blocks
  #     until `Page.lifecycleEvent` fires for that loader+milestone.
  #   * `{:await_next_page_load, name, timeout_ms}` → blocks until
  #     ANY lifecycle event of the given milestone fires.
  #   * `{:await_page_ready_after, pre_page_id, timeout_ms}` → blocks
  #     until the bootstrap reports a different `pageId`.
  #   * `{:await_find_result, query_id}` → blocks until the bootstrap
  #     fires `__wallabidi(...)` for that query id.
  #   * `{:register_find, query_id, timeout_ms}` → reserves a
  #     find-waiter slot before the JS that fires the binding runs.
  #   * `:current_context_id` → returns the focused frame's
  #     executionContextId (or nil for root).
  #   * `{:push_frame, context_id}` / `:pop_frame` /
  #     `:reset_frame_stack` → manage the frame focus stack.
  #   * `{:record_frame_context, frame_id, context_id}` /
  #     `{:lookup_frame_context, frame_id}` — frame_id ↔ context_id
  #     bookkeeping.
  #   * `:sync_barrier` → no-op call used as a mailbox barrier when
  #     the caller wants to ensure prior in-flight messages have
  #     drained.
  #   * `{:update_browsing_context, session_id, target_id}` →
  #     mutates the actor's session struct (used by focus_window).
  #
  # ### Asynchronous (`GenServer.cast`)
  #
  #   * `{:cdp_cast, method, params, opts}` → fire-and-forget CDP
  #     RPC. Response is dropped.
  #
  # ### Inbound (sent by the transport's connection layer)
  #
  #   * `{:v2_response, wire_id, result}` → response to a previously
  #     issued `cdp_send`/`cdp_cast`.
  #   * `{:v2_event, method, event_map}` → wire-level event the
  #     actor previously subscribed to.
  #
  # Lifecycle:
  #
  #   * The actor is started by a transport-specific function (e.g.
  #     `Transport.PerSession.acquire/1`,
  #     `Transport.IsolatedProcess.acquire/1`).
  #   * The actor monitors its owner; if the owner dies, it stops
  #     itself and runs its teardown_fun.
  #   * `stop/1` triggers an orderly shutdown.

  alias Wallabidi.Session

  @default_timeout 30_000

  # ----- Synchronous CDP RPC -----

  @spec cdp_send(Session.t(), String.t(), map, keyword) :: {:ok, term} | {:error, term}
  def cdp_send(%Session{pid: pid}, method, params, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:cdp_send, method, params, opts}, @default_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
  end

  @spec cdp_cast(Session.t(), String.t(), map, keyword) :: :ok
  def cdp_cast(%Session{pid: pid}, method, params, opts \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:cdp_cast, method, params, opts})
  end

  # ----- Subscription -----

  @spec subscribe(Session.t(), String.t(), :global | nil) :: :ok
  def subscribe(%Session{pid: pid}, event_method, routing_key \\ nil)
      when is_binary(event_method) do
    GenServer.call(pid, {:subscribe, event_method, routing_key})
  end

  # ----- Page-load & page-ready awaits -----

  @spec await_page_load(Session.t(), String.t(), String.t(), timeout) :: :ok | :timeout
  def await_page_load(%Session{pid: pid}, loader_id, name, timeout_ms \\ 10_000)
      when is_binary(loader_id) and is_binary(name) do
    GenServer.call(pid, {:await_page_load, loader_id, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @spec await_next_page_load(Session.t(), String.t(), timeout) :: :ok | :timeout
  def await_next_page_load(%Session{pid: pid}, name \\ "load", timeout_ms \\ 10_000)
      when is_binary(name) do
    GenServer.call(pid, {:await_next_page_load, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @spec await_page_ready_after(Session.t(), String.t() | nil, timeout) :: :ok | :timeout
  def await_page_ready_after(%Session{pid: pid}, pre_page_id, timeout_ms \\ 5_000) do
    # The server may extend the inner timer if a `nav_pending` arrives
    # (LV transition in flight, dest mount slow). Allow up to 12s of
    # slack on top of the caller's budget so the GenServer.call doesn't
    # cap the extension. The server's own timer is still the source of
    # truth for the actual deadline.
    GenServer.call(pid, {:await_page_ready_after, pre_page_id, timeout_ms}, timeout_ms + 12_000)
  catch
    :exit, _ -> :timeout
  end

  # ----- Find waiters -----

  @spec register_find(Session.t(), String.t(), timeout) :: :ok
  def register_find(%Session{pid: pid}, query_id, timeout_ms) when is_binary(query_id) do
    GenServer.call(pid, {:register_find, query_id, timeout_ms})
  end

  @spec await_find_result(Session.t(), String.t(), timeout) ::
          {:ok, non_neg_integer, map}
          | {:error, :invalid_selector}
          | {:timeout, non_neg_integer}
  def await_find_result(%Session{pid: pid}, query_id, timeout_ms)
      when is_binary(query_id) do
    GenServer.call(pid, {:await_find_result, query_id}, timeout_ms + 2_000)
  catch
    :exit, _ -> {:timeout, 0}
  end

  # ----- Frame stack -----

  @spec current_context_id(Session.t()) :: integer | nil
  def current_context_id(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :current_context_id)
  catch
    :exit, _ -> nil
  end

  @spec get_page_id(Session.t()) :: String.t() | nil
  def get_page_id(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :get_page_id)
  catch
    :exit, _ -> nil
  end

  @spec push_frame(Session.t(), integer) :: :ok
  def push_frame(%Session{pid: pid}, context_id) when is_integer(context_id) do
    GenServer.call(pid, {:push_frame, context_id})
  catch
    :exit, _ -> :ok
  end

  @spec pop_frame(Session.t()) :: :ok
  def pop_frame(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :pop_frame)
  catch
    :exit, _ -> :ok
  end

  @spec record_frame_context(Session.t(), String.t(), integer) :: :ok
  def record_frame_context(%Session{pid: pid}, frame_id, context_id)
      when is_binary(frame_id) and is_integer(context_id) do
    GenServer.call(pid, {:record_frame_context, frame_id, context_id})
  end

  @spec lookup_frame_context(Session.t(), String.t()) :: integer | nil
  def lookup_frame_context(%Session{pid: pid}, frame_id) when is_binary(frame_id) do
    GenServer.call(pid, {:lookup_frame_context, frame_id})
  catch
    :exit, _ -> nil
  end

  # ----- Misc -----

  @spec sync_barrier(Session.t()) :: :ok
  def sync_barrier(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :sync_barrier)
  catch
    :exit, _ -> :ok
  end

  def sync_barrier(_), do: :ok

  @spec stop(Session.t()) :: :ok
  def stop(%Session{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def stop(_), do: :ok
end
