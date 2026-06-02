defmodule Wallabidi.Integration.SessionCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallabidi.DSL
      import Wallabidi.Integration.SessionCase
    end
  end

  setup :inject_test_session
  setup :guard_event_driven_awaits

  @doc false
  def guard_event_driven_awaits(context) do
    test_pid = self()

    on_exit(fn ->
      # Fail the test if any event-driven await fell back to its timeout
      # during the body (a masked regression — see
      # Wallabidi.Test.AwaitMonitor). Runs in a separate process, so pass
      # the captured test_pid; context carries the name + any
      # @tag :expected_await_timeout opt-out.
      Wallabidi.Test.AwaitMonitor.check!(test_pid, context)
    end)

    :ok
  end

  @doc """
  Starts a test session with the default opts for the given driver
  """
  def start_test_session(opts \\ []) do
    # 4 retries gives BiDi room to weather a chromium-bidi session.subscribe
    # timeout (occasional on slow CI runners) or a singleton BidiServer
    # restart without failing the test.
    retry(4, fn -> Wallabidi.start_session(opts) end)
  end

  @doc """
  Injects a test session into the test context
  """
  def inject_test_session(%{skip_test_session: true}), do: :ok

  def inject_test_session(_context) do
    {:ok, session} = start_test_session()

    {:ok, %{session: session}}
  end

  defp retry(0, f), do: f.()

  defp retry(times, f) do
    case f.() do
      {:ok, session} ->
        {:ok, session}

      _ ->
        Process.sleep(250)
        retry(times - 1, f)
    end
  end
end
