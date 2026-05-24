defmodule Wallabidi.Remote.Transport.Common do
  @moduledoc false

  # Shared per-session state-machine helpers used by all three Transport
  # actors:
  #
  #   * `Wallabidi.Remote.Transport.Session` (Chrome CDP, shared WS)
  #   * `Wallabidi.Remote.Transport.PerSession.Actor` (Lightpanda, per-session WS)
  #   * `Wallabidi.Remote.Transport.BiDi.SessionActor` (Chrome BiDi, per-session WS)
  #
  # Each actor owns its own wire protocol (CDP/BiDi) and connection model
  # (shared vs per-session WS), but they all maintain the same waiter
  # state machine for find / page-load / page-ready / frame tracking.
  # Centralising that here keeps the three implementations from drifting.

  # ----- Find waiters -----

  @doc """
  Registers a find query with an in-flight timeout. The caller will
  subsequently call `await_find_result/1` and either get the resolved
  result or a `:timeout` once the timer fires.
  """
  @spec register_find(map(), term(), non_neg_integer()) :: map()
  def register_find(state, query_id, timeout_ms) do
    timer_ref = Process.send_after(self(), {:find_timeout, query_id}, timeout_ms)
    %{state | find_waiters: Map.put(state.find_waiters, query_id, {:pending, timer_ref, nil})}
  end

  @doc """
  Looks up a registered find result, suspending the caller if not yet
  resolved. Returns `{:reply, ...}` / `{:noreply, ...}` shapes ready to
  return from `handle_call/3`.
  """
  @spec await_find_result(map(), term(), GenServer.from()) ::
          {:reply, term(), map()} | {:noreply, map()}
  def await_find_result(state, query_id, from) do
    case Map.get(state.find_waiters, query_id) do
      {:resolved, result} ->
        {:reply, result, %{state | find_waiters: Map.delete(state.find_waiters, query_id)}}

      {:pending, timer_ref, nil} ->
        waiters = Map.put(state.find_waiters, query_id, {:pending, timer_ref, from})
        {:noreply, %{state | find_waiters: waiters}}

      nil ->
        {:reply, {:timeout, 0}, state}
    end
  end

  @doc """
  Resolves a registered find with a result. If a caller is already
  awaiting, replies immediately and drops the entry; otherwise stashes
  the result for an arriving caller and cancels the pending timer.
  """
  @spec resolve_find(map(), term(), term()) :: map()
  def resolve_find(state, query_id, result) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        state

      {:resolved, _} ->
        state

      {:pending, timer_ref, nil} ->
        Process.cancel_timer(timer_ref)
        %{state | find_waiters: Map.put(state.find_waiters, query_id, {:resolved, result})}

      {:pending, timer_ref, from} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}
    end
  end

  @doc """
  Handles a `{:find_timeout, query_id}` message — drops the pending entry
  and replies `:timeout` to any awaiter. Resolved entries are kept (the
  awaiter will pop them via `await_find_result/3`).
  """
  @spec handle_find_timeout(map(), term()) :: map()
  def handle_find_timeout(state, query_id) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        state

      {:resolved, _} ->
        state

      {:pending, _ref, nil} ->
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}

      {:pending, _ref, from} ->
        GenServer.reply(from, {:timeout, 0})
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}
    end
  end

  # ----- Page-ready waiter -----

  @doc """
  Suspends or replies based on whether a new pageId has already arrived
  relative to `pre_page_id`. Returns a handle_call-shaped tuple.
  """
  @spec await_page_ready_after(map(), term() | nil, non_neg_integer(), GenServer.from()) ::
          {:reply, :ok, map()} | {:noreply, map()}
  def await_page_ready_after(state, pre_page_id, timeout_ms, from) do
    if pre_page_id != nil and state.last_page_id != nil and
         state.last_page_id != pre_page_id do
      {:reply, :ok, state}
    else
      timer_ref = Process.send_after(self(), {:page_ready_timeout, from}, timeout_ms)
      {:noreply, %{state | page_ready_waiter: {from, pre_page_id, timer_ref}}}
    end
  end

  @doc """
  Records the most recent pageId and wakes any waiter whose `pre_page_id`
  differs (i.e. a transition has occurred).
  """
  @spec update_last_page_id(map(), term()) :: map()
  def update_last_page_id(state, page_id) do
    state = %{state | last_page_id: page_id}

    case state.page_ready_waiter do
      {from, pre_page_id, timer_ref} when pre_page_id != page_id ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, :ok)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  @doc """
  Handles a `{:page_ready_timeout, from}` message. Replies `:timeout` only
  if the waiter is still the one named in the message.
  """
  @spec handle_page_ready_timeout(map(), GenServer.from()) :: map()
  def handle_page_ready_timeout(state, from) do
    case state.page_ready_waiter do
      {^from, _pre, _ref} ->
        GenServer.reply(from, :timeout)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  # ----- Frame stack -----

  @doc "Pushes a context_id (or browsing-context-id) onto the frame stack."
  @spec push_frame(map(), term()) :: map()
  def push_frame(state, context_id) do
    %{state | frame_stack: [context_id | state.frame_stack]}
  end

  @doc "Pops the top entry off the frame stack, leaving an empty stack alone."
  @spec pop_frame(map()) :: map()
  def pop_frame(state) do
    case state.frame_stack do
      [] -> state
      [_ | rest] -> %{state | frame_stack: rest}
    end
  end

  @doc "Returns the current frame's context id (top of stack) or nil."
  @spec current_context_id(map()) :: term() | nil
  def current_context_id(state), do: List.first(state.frame_stack)

  @doc "Stores a `frame_id => context_id` mapping."
  @spec record_frame_context(map(), term(), term()) :: map()
  def record_frame_context(state, frame_id, context_id) do
    %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}
  end

  @doc "Looks up a previously-recorded context id for a frame."
  @spec lookup_frame_context(map(), term()) :: term() | nil
  def lookup_frame_context(state, frame_id) do
    Map.get(state.frame_contexts, frame_id)
  end

  # ----- Bootstrap channel payload routing -----

  @doc """
  Routes a JSON payload from the bootstrap channel (`__wallabidi(...)` in
  CDP, `script.message` in BiDi) to the appropriate state-machine update.
  Recognises find results and page_ready signals. Unknown payloads return
  the state unchanged.
  """
  @spec route_bootstrap_payload(map(), binary()) :: map()
  def route_bootstrap_payload(state, payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => query_id, "error" => err}} when is_binary(err) ->
        resolve_find(state, query_id, {:error, :invalid_selector})

      {:ok, %{"id" => query_id, "count" => count} = msg} ->
        resolve_find(state, query_id, {:ok, count, msg["meta"]})

      {:ok, %{"type" => "page_ready", "pageId" => page_id}} ->
        update_last_page_id(state, page_id)

      _ ->
        state
    end
  end

  def route_bootstrap_payload(state, _), do: state
end
