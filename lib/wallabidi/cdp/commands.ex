defmodule Wallabidi.CDP.Commands do
  @moduledoc false

  # Browser context management (incognito-like isolation)

  def create_browser_context do
    {"Target.createBrowserContext", %{disposeOnDetach: true}}
  end

  def dispose_browser_context(browser_context_id) do
    {"Target.disposeBrowserContext", %{browserContextId: browser_context_id}}
  end

  # Target management

  def create_target(url \\ "about:blank", opts \\ []) do
    params = %{url: url}

    params =
      case Keyword.get(opts, :browser_context_id) do
        nil -> params
        id -> Map.put(params, :browserContextId, id)
      end

    {"Target.createTarget", params}
  end

  def attach_to_target(target_id) do
    {"Target.attachToTarget", %{targetId: target_id, flatten: true}}
  end

  def close_target(target_id) do
    {"Target.closeTarget", %{targetId: target_id}}
  end

  # Domain enablement

  def enable_page, do: {"Page.enable", %{}}
  def enable_runtime, do: {"Runtime.enable", %{}}
  def enable_network, do: {"Network.enable", %{}}
  def enable_dom, do: {"DOM.enable", %{}}

  # Navigation

  def navigate(url) do
    {"Page.navigate", %{url: url}}
  end

  # Script execution

  def evaluate(expression, opts \\ []) do
    params = %{
      expression: expression,
      returnByValue: Keyword.get(opts, :return_by_value, true),
      awaitPromise: Keyword.get(opts, :await_promise, false)
    }

    {"Runtime.evaluate", params}
  end

  def call_function_on(object_id, function_declaration, arguments \\ []) do
    params = %{
      objectId: object_id,
      functionDeclaration: function_declaration,
      arguments: Enum.map(arguments, &encode_argument/1),
      returnByValue: false
    }

    {"Runtime.callFunctionOn", params}
  end

  def call_function_on_value(object_id, function_declaration, arguments \\ []) do
    params = %{
      objectId: object_id,
      functionDeclaration: function_declaration,
      arguments: Enum.map(arguments, &encode_argument/1),
      returnByValue: true
    }

    {"Runtime.callFunctionOn", params}
  end

  def get_properties(object_id, opts \\ []) do
    params = %{
      objectId: object_id,
      ownProperties: Keyword.get(opts, :own_properties, true)
    }

    {"Runtime.getProperties", params}
  end

  def release_object(object_id) do
    {"Runtime.releaseObject", %{objectId: object_id}}
  end

  # Input

  def dispatch_key_event(type, opts \\ []) do
    params =
      %{type: type}
      |> maybe_put(:text, opts[:text])
      |> maybe_put(:key, opts[:key])
      |> maybe_put(:code, opts[:code])
      |> maybe_put(:windowsVirtualKeyCode, opts[:key_code])

    {"Input.dispatchKeyEvent", params}
  end

  # Network / Cookies

  def get_cookies do
    {"Network.getCookies", %{}}
  end

  def set_cookie(name, value, opts \\ []) do
    params =
      %{name: name, value: value}
      |> maybe_put(:domain, opts[:domain])
      |> maybe_put(:path, opts[:path])
      |> maybe_put(:secure, opts[:secure])
      |> maybe_put(:httpOnly, opts[:http_only])

    {"Network.setCookie", params}
  end

  def delete_cookies(name, opts \\ []) do
    params =
      %{name: name}
      |> maybe_put(:domain, opts[:domain])

    {"Network.deleteCookies", params}
  end

  # Screenshots

  def capture_screenshot(opts \\ []) do
    params = %{format: Keyword.get(opts, :format, "png")}
    {"Page.captureScreenshot", params}
  end

  # Window / Emulation

  def set_device_metrics(width, height) do
    {"Emulation.setDeviceMetricsOverride",
     %{width: width, height: height, deviceScaleFactor: 1, mobile: false}}
  end

  def clear_device_metrics do
    {"Emulation.clearDeviceMetricsOverride", %{}}
  end

  def set_user_agent_override(user_agent, opts \\ []) do
    params =
      %{userAgent: user_agent}
      |> maybe_put(:acceptLanguage, opts[:accept_language])
      |> maybe_put(:platform, opts[:platform])

    {"Emulation.setUserAgentOverride", params}
  end

  # Dialogs

  def handle_dialog(accept, opts \\ []) do
    params =
      %{accept: accept}
      |> maybe_put(:promptText, opts[:prompt_text])

    {"Page.handleJavaScriptDialog", params}
  end

  # Helpers

  defp encode_argument(value) when is_binary(value), do: %{value: value}
  defp encode_argument(value) when is_number(value), do: %{value: value}
  defp encode_argument(value) when is_boolean(value), do: %{value: value}
  defp encode_argument(nil), do: %{value: nil}
  defp encode_argument(%{objectId: id}), do: %{objectId: id}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
