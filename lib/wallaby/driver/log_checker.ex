defmodule Wallabidi.Driver.LogChecker do
  @moduledoc false

  # Drains buffered BiDi log events from the process mailbox and
  # passes them to the driver's parse_log/1 for JS error detection
  # and console output.

  @internal_log_patterns ["Launching Mapper instance"]

  def check_logs!(%{driver: driver} = _session, fun) do
    return_value = fun.()

    drain_log_events()
    |> Enum.each(&driver.parse_log/1)

    return_value
  end

  defp drain_log_events do
    receive do
      {:bidi_event, "log.entryAdded", event} ->
        case translate_log_entry(event) do
          :skip -> drain_log_events()
          entry -> [entry | drain_log_events()]
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
