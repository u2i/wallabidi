defmodule Wallabidi.Integration.Chrome.TraceConnectionTest do
  @moduledoc false
  # Minimal test: create N sessions on the shared connection and see if it survives.
  use ExUnit.Case, async: false

  alias Wallabidi.CDPClient
  alias Wallabidi.ChromeCDP.SharedConnection

  @moduletag :browser

  test "shared connection survives 20 concurrent sessions" do
    cdp_pid = SharedConnection.get()
    assert Process.alive?(cdp_pid)

    sessions =
      for i <- 1..20 do
        {:ok, %{"browserContextId" => ctx_id}} = CDPClient.create_browser_context(cdp_pid)

        {:ok, %{target_id: tid, session_id: sid}} =
          CDPClient.create_session(cdp_pid, flat_session_id: true, browser_context_id: ctx_id)

        IO.write("#{i} ")
        %{ctx_id: ctx_id, target_id: tid, session_id: sid}
      end

    IO.puts(
      "\n  #{length(sessions)} sessions created, connection alive=#{Process.alive?(cdp_pid)}"
    )

    # Do a trivial eval on each to confirm they work
    for {s, i} <- Enum.with_index(sessions, 1) do
      result =
        Wallabidi.BiDi.WebSocketClient.send_command_flat(
          cdp_pid,
          "Runtime.evaluate",
          %{expression: "1+1", returnByValue: true},
          s.session_id
        )

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> IO.puts("  session #{i} eval failed: #{inspect(reason)}")
      end
    end

    IO.puts("  all evals done, connection alive=#{Process.alive?(cdp_pid)}")

    # Cleanup
    for s <- sessions do
      CDPClient.dispose_browser_context(cdp_pid, s.ctx_id)
    end

    assert Process.alive?(cdp_pid), "shared connection died"
  end
end
