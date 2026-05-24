defmodule Wallabidi.Remote.Frames.ChromeCDP do
  @moduledoc false

  @behaviour Wallabidi.Remote.Frames

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.CDP.Client, as: CDPClient

  @impl true
  def focus_frame(%Session{} = session, %Element{handle: object_id})
      when is_binary(object_id) do
    # Resolve the iframe element's frameId via DOM.describeNode, then
    # ask Session to push the frame's executionContextId so all
    # subsequent script evals target it.
    case CDPClient.cdp_send(session, "DOM.describeNode", %{objectId: object_id}) do
      {:ok, %{"node" => %{"frameId" => frame_id}}} when is_binary(frame_id) ->
        case CDPClient.focus_frame_by_id(session, frame_id) do
          :ok -> {:ok, nil}
          err -> err
        end

      _ ->
        {:ok, nil}
    end
  end

  # Browser.focus_default_frame/1 calls driver.focus_frame(session, nil)
  # to escape all the way out. Reset the frame stack.
  def focus_frame(%Session{pid: pid}, nil) when is_pid(pid) do
    GenServer.call(pid, :reset_frame_stack)
    {:ok, nil}
  end

  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(%Session{} = session) do
    :ok = CDPClient.focus_parent_frame(session)
    {:ok, nil}
  end

  def focus_parent_frame(_), do: {:ok, nil}
end
