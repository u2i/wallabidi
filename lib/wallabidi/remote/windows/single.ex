defmodule Wallabidi.Remote.Windows.Single do
  @moduledoc false

  # Single-window stub for drivers without multi-window support
  # (currently Lightpanda). All sessions report a single window
  # handle "main"; focus/close are no-ops.

  @behaviour Wallabidi.Remote.Windows

  @impl true
  def window_handle(_), do: {:ok, "main"}

  @impl true
  def window_handles(_), do: {:ok, ["main"]}

  @impl true
  def focus_window(_, _), do: {:ok, nil}

  @impl true
  def close_window(_), do: {:ok, nil}
end
