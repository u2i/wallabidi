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

      {:bidi_event, "Runtime.consoleAPICalled", event} ->
        [translate_cdp_console(event) | drain_log_events()]

      {:bidi_event, "Runtime.exceptionThrown", event} ->
        [translate_cdp_exception(event) | drain_log_events()]
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

  # CDP Runtime.consoleAPICalled → same format as BiDi log entries
  defp translate_cdp_console(event) do
    params = event["params"] || %{}
    type = params["type"] || "log"

    level =
      case type do
        "error" -> "SEVERE"
        "warning" -> "WARNING"
        "debug" -> "DEBUG"
        _ -> "INFO"
      end

    args = params["args"] || []

    text =
      Enum.map_join(args, " ", fn
        %{"value" => v} when is_binary(v) -> v
        %{"value" => v} -> inspect(v)
        %{"description" => d} -> d
        %{"type" => "undefined"} -> "undefined"
        other -> inspect(other)
      end)

    trace = params["stackTrace"] || %{}
    frames = trace["callFrames"] || []
    {url, line, col} = extract_stack_location(frames)

    %{
      "level" => level,
      "source" => "console-api",
      "message" => "#{url} #{line}:#{col} #{text}"
    }
  end

  # CDP Runtime.exceptionThrown → SEVERE log entry
  defp translate_cdp_exception(event) do
    params = event["params"] || %{}
    detail = params["exceptionDetails"] || %{}
    exception = detail["exception"] || %{}
    text = exception["description"] || detail["text"] || "Unknown error"

    url = detail["url"] || "unknown"
    line = detail["lineNumber"] || 0
    col = detail["columnNumber"] || 0

    %{
      "level" => "SEVERE",
      "source" => "javascript",
      "message" => "#{url} #{line}:#{col} #{text}"
    }
  end

  defp extract_stack_location([%{"url" => url, "lineNumber" => line, "columnNumber" => col} | _]),
    do: {url, line, col}

  defp extract_stack_location(_), do: {"unknown", 0, 0}
end
