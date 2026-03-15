defmodule Wallaby.Driver.LogChecker do
  @moduledoc false
  alias Wallaby.Driver.LogStore

  def check_logs!(%{driver: driver} = session, fun) do
    return_value = fun.()

    if bidi_session?(session) do
      # For BiDi sessions, drain buffered log events from the process mailbox.
      # Events are already being pushed via the WebSocket subscription established
      # at session creation time, so no HTTP round-trip is needed.
      logs = drain_bidi_log_events()

      session.session_url
      |> LogStore.append_logs(logs)
      |> Enum.each(&driver.parse_log/1)
    else
      {:ok, logs} = driver.log(session)

      session.session_url
      |> LogStore.append_logs(logs)
      |> Enum.each(&driver.parse_log/1)
    end

    return_value
  end

  defp bidi_session?(%Wallaby.Session{bidi_pid: pid}) when not is_nil(pid), do: true
  defp bidi_session?(%Wallaby.Element{parent: parent}), do: bidi_session?(parent)
  defp bidi_session?(_), do: false

  # Internal log patterns to filter out (chromedriver BiDi mapper noise)
  @internal_log_patterns ["Launching Mapper instance"]

  defp drain_bidi_log_events do
    receive do
      {:bidi_event, "log.entryAdded", event} ->
        case translate_log_entry(event) do
          :skip -> drain_bidi_log_events()
          entry -> [entry | drain_bidi_log_events()]
        end
    after
      0 -> []
    end
  end

  defp translate_log_entry(event) do
    params = event["params"] || %{}
    text = params["text"] || ""

    if Enum.any?(@internal_log_patterns, &String.contains?(text, &1)) do
      :skip
    else
      level =
        case params["level"] do
          "error" -> "SEVERE"
          "warning" -> "WARNING"
          "info" -> "INFO"
          "debug" -> "DEBUG"
          other -> other || "INFO"
        end

      source =
        case params["type"] do
          "javascript" -> "javascript"
          "console" -> "console-api"
          other -> other || "other"
        end

      source_info = params["source"] || %{}
      url = source_info["url"] || ""
      line = params["lineNumber"] || 0
      column = params["columnNumber"] || 0

      message =
        if url != "" do
          "#{url} #{line}:#{column} #{text}"
        else
          "unknown 0:0 #{text}"
        end

      %{
        "level" => level,
        "source" => source,
        "message" => message
      }
    end
  end
end
