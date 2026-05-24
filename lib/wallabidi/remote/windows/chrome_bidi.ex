defmodule Wallabidi.Remote.Windows.ChromeBiDi do
  @moduledoc false

  # Window/tab management for Chrome over BiDi. Uses
  # `BiDiClient.window_handles/1` and stores "which window is focused"
  # in the test process's process dictionary (keyed by session id) so
  # the focus override is per-test, not global.

  @behaviour Wallabidi.Remote.Windows

  alias Wallabidi.Remote.BiDi.Client, as: BiDiClient
  alias Wallabidi.Session

  @impl true
  def window_handle(%Session{} = session) do
    {:ok, current_window(session)}
  end

  @impl true
  def window_handles(%Session{} = session) do
    BiDiClient.window_handles(session)
  end

  @impl true
  def focus_window(%Session{} = session, handle) when is_binary(handle) do
    Process.put({:wallabidi_bidi_v2_window, session.id}, handle)
    # Reset frame state: switching tabs invalidates iframe focus.
    Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
    Process.put({:wallabidi_bidi_v2_frame, session.id}, handle)
    {:ok, nil}
  end

  @impl true
  def close_window(%Session{} = session) do
    handle = current_window(session)

    case BiDiClient.close_window(session, handle) do
      :ok ->
        Process.delete({:wallabidi_bidi_v2_window, session.id})
        Process.delete({:wallabidi_bidi_v2_frame, session.id})
        Process.delete({:wallabidi_bidi_v2_frame_stack, session.id})
        {:ok, nil}

      err ->
        err
    end
  end

  defp current_window(%Session{id: id, browsing_context: root}) do
    Process.get({:wallabidi_bidi_v2_window, id}, root)
  end
end
