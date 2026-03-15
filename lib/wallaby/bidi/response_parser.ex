defmodule Wallabidi.BiDi.ResponseParser do
  @moduledoc false
  # Translates BiDi response formats into the shapes Wallabidi expects.

  @doc """
  Extracts a primitive value from a BiDi script result.
  BiDi returns results like %{"type" => "string", "value" => "hello"}.
  """
  def extract_value(%{"type" => "exception", "exceptionDetails" => details}) do
    # Script threw an error — check if it's a stale element reference
    message = get_in(details, ["text"]) || ""
    exception = details["exception"] || %{}
    exception_message = get_in(exception, ["value", "message"]) || ""
    full_message = message <> " " <> exception_message

    if String.contains?(full_message, "stale element") do
      {:error, :stale_reference}
    else
      {:error, {:script_exception, full_message}}
    end
  end

  def extract_value(%{"result" => result}), do: extract_value(result)

  def extract_value(%{"type" => "string", "value" => value}), do: {:ok, value}
  def extract_value(%{"type" => "number", "value" => value}), do: {:ok, value}
  def extract_value(%{"type" => "boolean", "value" => value}), do: {:ok, value}
  def extract_value(%{"type" => "null"}), do: {:ok, nil}
  def extract_value(%{"type" => "undefined"}), do: {:ok, nil}

  def extract_value(%{"type" => "array", "value" => items}) do
    results =
      Enum.map(items, fn item ->
        case extract_value(item) do
          {:ok, v} -> v
          {:error, _} -> nil
        end
      end)

    {:ok, results}
  end

  def extract_value(%{"type" => "object", "value" => pairs}) do
    map =
      pairs
      |> Enum.map(fn [key, value] ->
        key_str = extract_object_key(key)

        val =
          case extract_value(value) do
            {:ok, v} -> v
            _ -> nil
          end

        {key_str, val}
      end)
      |> Map.new()

    {:ok, map}
  end

  def extract_value(%{"type" => "node", "sharedId" => shared_id} = node) do
    {:ok, {:node, shared_id, node}}
  end

  def extract_value(%{"type" => "window"}), do: {:ok, nil}
  def extract_value(%{"type" => "regexp", "value" => value}), do: {:ok, value}
  def extract_value(%{"type" => "date", "value" => value}), do: {:ok, value}

  def extract_value(%{"type" => "map", "value" => value}),
    do: extract_value(%{"type" => "object", "value" => value})

  def extract_value(%{"type" => "set", "value" => items}),
    do: extract_value(%{"type" => "array", "value" => items})

  def extract_value(%{"type" => "bigint", "value" => value}), do: {:ok, value}

  def extract_value(other), do: {:error, {:unexpected_value, other}}

  defp extract_object_key(key) when is_binary(key), do: key

  defp extract_object_key(key) do
    case extract_value(key) do
      {:ok, v} -> to_string(v)
      _ -> inspect(key)
    end
  end

  @doc """
  Extracts element nodes from a locateNodes response.
  Returns a list of {shared_id, node_map} tuples.
  """
  def extract_nodes(%{"nodes" => nodes}) do
    elements =
      Enum.map(nodes, fn node ->
        shared_id = node["sharedId"]
        {shared_id, node}
      end)

    {:ok, elements}
  end

  def extract_nodes(other), do: {:error, {:unexpected_nodes_response, other}}

  @doc """
  Converts BiDi element nodes into Wallabidi Element structs.
  """
  def cast_elements(parent, nodes) do
    Enum.map(nodes, fn {shared_id, node} ->
      # Use the shared_id as the element id for WebDriver compat
      # The BackendNodeId is used for the element URL
      value = node["value"] || %{}
      backend_node_id = to_string(value["backendNodeId"] || shared_id)

      # Store the mapping from element ID to shared ID so that
      # WebDriver-style element references (used in execute_script args)
      # can be resolved back to BiDi shared IDs.
      Process.put({:wallabidi_element_shared_id, backend_node_id}, shared_id)

      %Wallabidi.Element{
        id: backend_node_id,
        session_url: parent.session_url,
        url: parent.session_url <> "/element/#{backend_node_id}",
        parent: parent,
        driver: parent.driver,
        bidi_shared_id: shared_id
      }
    end)
  end

  @doc """
  Extracts browsing context info from a getTree response.
  """
  def extract_context(%{"contexts" => [context | _]}) do
    {:ok, context["context"]}
  end

  def extract_context(other), do: {:error, {:unexpected_tree_response, other}}

  @doc """
  Extracts all context IDs from a getTree response (for window_handles).
  """
  def extract_all_contexts(%{"contexts" => contexts}) do
    ids = Enum.map(contexts, fn ctx -> ctx["context"] end)
    {:ok, ids}
  end

  def extract_all_contexts(other), do: {:error, {:unexpected_tree_response, other}}

  @doc """
  Extracts the screenshot data from a captureScreenshot response.
  """
  def extract_screenshot(%{"data" => data}) do
    {:ok, :base64.decode(data)}
  end

  def extract_screenshot(other), do: {:error, {:unexpected_screenshot_response, other}}

  @doc """
  Extracts cookies from a getCookies response.
  """
  def extract_cookies(%{"cookies" => cookies}) do
    normalized =
      Enum.map(cookies, fn cookie ->
        %{
          "name" => cookie["name"],
          "value" => Map.get(cookie["value"] || %{}, "value", ""),
          "domain" => cookie["domain"],
          "path" => cookie["path"],
          "secure" => cookie["secure"],
          "httpOnly" => cookie["httpOnly"],
          "expiry" => cookie["expiry"]
        }
      end)

    {:ok, normalized}
  end

  def extract_cookies(other), do: {:error, {:unexpected_cookies_response, other}}

  @doc """
  Checks a BiDi error response for known WebDriver error patterns.
  """
  def check_error({:error, {"no such element", _}}), do: {:error, :stale_reference}
  def check_error({:error, {"stale element reference", _}}), do: {:error, :stale_reference}
  def check_error({:error, {"no such node", _}}), do: {:error, :stale_reference}
  def check_error({:error, {"invalid selector", _}}), do: {:error, :invalid_selector}
  def check_error({:error, {"element click intercepted", _}}), do: {:error, :obscured}
  def check_error({:error, {"element not interactable", _msg}}), do: {:error, :obscured}
  def check_error({:error, {"no such frame", _}}), do: {:error, :no_such_frame}

  def check_error({:error, {_error, message}} = original) when is_binary(message) do
    if String.contains?(message, "stale element") do
      {:error, :stale_reference}
    else
      original
    end
  end

  def check_error(other), do: other
end
