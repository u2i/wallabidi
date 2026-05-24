defmodule Wallabidi.Remote.Frames.ChromeBiDi do
  @moduledoc false

  @behaviour Wallabidi.Remote.Frames

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient

  @impl true
  def focus_frame(%Session{} = session, %Element{} = iframe) do
    case BiDiClient.child_context_for_iframe(session, iframe) do
      {:ok, child_ctx} ->
        # Push the current context onto the per-test frame stack so
        # focus_parent_frame can pop back. The override is read by
        # BiDiClient.ctx/1 on every BiDi op — find/click/evaluate
        # all retarget to the focused iframe automatically.
        stack = Process.get({:wallabidi_bidi_v2_frame_stack, session.id}, [])
        current = current_ctx(session)
        Process.put({:wallabidi_bidi_v2_frame_stack, session.id}, [current | stack])
        Process.put({:wallabidi_bidi_v2_frame, session.id}, child_ctx)
        # Browser.in_frame? checks for this proc-dict key to skip the
        # click_aware fast path (legacy behavior — frame-scoped
        # clicks don't go through bootstrap).
        Process.put({:wallabidi_frame_context, session.id}, child_ctx)
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  # Browser.focus_default_frame/1 calls driver.focus_frame(session, nil)
  # to escape all the way out — clear the frame stack + override.
  def focus_frame(%Session{} = session, nil) do
    Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
    Process.delete({:wallabidi_bidi_v2_frame, session.id})
    Process.delete({:wallabidi_frame_context, session.id})
    {:ok, nil}
  end

  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(%Session{} = session) do
    case Process.get({:wallabidi_bidi_v2_frame_stack, session.id}, []) do
      [] ->
        # Already at root.
        {:ok, nil}

      [parent_ctx | rest] ->
        Process.put({:wallabidi_bidi_v2_frame_stack, session.id}, rest)

        if rest == [] and parent_ctx == session.browsing_context do
          Process.delete({:wallabidi_bidi_v2_frame, session.id})
          Process.delete({:wallabidi_frame_context, session.id})
        else
          Process.put({:wallabidi_bidi_v2_frame, session.id}, parent_ctx)
          Process.put({:wallabidi_frame_context, session.id}, parent_ctx)
        end

        {:ok, nil}
    end
  end

  def focus_parent_frame(_), do: {:ok, nil}

  defp current_ctx(%Session{id: id, browsing_context: root}) do
    Process.get({:wallabidi_bidi_v2_frame, id}, root)
  end
end
