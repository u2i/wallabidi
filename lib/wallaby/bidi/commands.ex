defmodule Wallaby.BiDi.Commands do
  @moduledoc false
  # Pure functions building BiDi command payloads (method + params maps).

  # Browsing Context commands

  def navigate(context, url) do
    {"browsingContext.navigate", %{context: context, url: url, wait: "complete"}}
  end

  def get_tree(opts \\ %{}) do
    {"browsingContext.getTree", opts}
  end

  def capture_screenshot(context) do
    {"browsingContext.captureScreenshot", %{context: context}}
  end

  def close_context(context) do
    {"browsingContext.close", %{context: context}}
  end

  def activate(context) do
    {"browsingContext.activate", %{context: context}}
  end

  def locate_nodes(context, locator) do
    {"browsingContext.locateNodes", %{context: context, locator: locator}}
  end

  def locate_nodes(context, locator, start_nodes) do
    {"browsingContext.locateNodes",
     %{context: context, locator: locator, startNodes: start_nodes}}
  end

  # Script commands

  def evaluate(context, expression, opts \\ %{}) do
    params =
      Map.merge(
        %{
          expression: expression,
          target: %{context: context},
          awaitPromise: Map.get(opts, :await_promise, false),
          resultOwnership: "root"
        },
        Map.drop(opts, [:await_promise])
      )

    {"script.evaluate", params}
  end

  def call_function(context, function_declaration, arguments \\ [], opts \\ %{}) do
    params =
      Map.merge(
        %{
          functionDeclaration: function_declaration,
          arguments: arguments,
          target: %{context: context},
          awaitPromise: Map.get(opts, :await_promise, false),
          resultOwnership: "root"
        },
        Map.drop(opts, [:await_promise])
      )

    {"script.callFunction", params}
  end

  # Input commands

  def perform_actions(context, actions) do
    {"input.performActions", %{context: context, actions: actions}}
  end

  # Storage commands

  def get_cookies(opts \\ %{}) do
    {"storage.getCookies", opts}
  end

  def set_cookie(cookie, opts \\ %{}) do
    {"storage.setCookie", Map.merge(%{cookie: cookie}, opts)}
  end

  # Helper: Build a pointer click action sequence for an element
  def pointer_click_actions(element_shared_id) do
    [
      %{
        type: "pointer",
        id: "mouse",
        parameters: %{pointerType: "mouse"},
        actions: [
          %{
            type: "pointerMove",
            origin: %{type: "element", element: %{sharedId: element_shared_id}},
            x: 0,
            y: 0
          },
          %{type: "pointerDown", button: 0},
          %{type: "pointerUp", button: 0}
        ]
      }
    ]
  end

  # Helper: Build key actions for typing text
  def key_type_actions(text) when is_binary(text) do
    key_actions =
      text
      |> String.graphemes()
      |> Enum.flat_map(fn char ->
        [
          %{type: "keyDown", value: char},
          %{type: "keyUp", value: char}
        ]
      end)

    [
      %{
        type: "key",
        id: "keyboard",
        actions: key_actions
      }
    ]
  end

  def key_type_actions(keys) when is_list(keys) do
    key_actions =
      keys
      |> Enum.flat_map(fn
        key when is_atom(key) ->
          value = key_code(key)
          [%{type: "keyDown", value: value}, %{type: "keyUp", value: value}]

        text when is_binary(text) ->
          text
          |> String.graphemes()
          |> Enum.flat_map(fn char ->
            [%{type: "keyDown", value: char}, %{type: "keyUp", value: char}]
          end)
      end)

    [
      %{
        type: "key",
        id: "keyboard",
        actions: key_actions
      }
    ]
  end

  # Helper: Build pointer move action for hovering
  def pointer_move_actions(element_shared_id) do
    [
      %{
        type: "pointer",
        id: "mouse",
        parameters: %{pointerType: "mouse"},
        actions: [
          %{
            type: "pointerMove",
            origin: %{type: "element", element: %{sharedId: element_shared_id}},
            x: 0,
            y: 0
          }
        ]
      }
    ]
  end

  # Key code mappings matching Wallaby.Helpers.KeyCodes
  defp key_code(:null), do: "\uE000"
  defp key_code(:cancel), do: "\uE001"
  defp key_code(:help), do: "\uE002"
  defp key_code(:backspace), do: "\uE003"
  defp key_code(:tab), do: "\uE004"
  defp key_code(:clear), do: "\uE005"
  defp key_code(:return), do: "\uE006"
  defp key_code(:enter), do: "\uE007"
  defp key_code(:shift), do: "\uE008"
  defp key_code(:control), do: "\uE009"
  defp key_code(:alt), do: "\uE00A"
  defp key_code(:pause), do: "\uE00B"
  defp key_code(:escape), do: "\uE00C"
  defp key_code(:space), do: "\uE00D"
  defp key_code(:pageup), do: "\uE00E"
  defp key_code(:pagedown), do: "\uE00F"
  defp key_code(:end), do: "\uE010"
  defp key_code(:home), do: "\uE011"
  defp key_code(:left_arrow), do: "\uE012"
  defp key_code(:up_arrow), do: "\uE013"
  defp key_code(:right_arrow), do: "\uE014"
  defp key_code(:down_arrow), do: "\uE015"
  defp key_code(:insert), do: "\uE016"
  defp key_code(:delete), do: "\uE017"
  defp key_code(:semicolon), do: "\uE018"
  defp key_code(:equals), do: "\uE019"
  defp key_code(:num0), do: "\uE01A"
  defp key_code(:num1), do: "\uE01B"
  defp key_code(:num2), do: "\uE01C"
  defp key_code(:num3), do: "\uE01D"
  defp key_code(:num4), do: "\uE01E"
  defp key_code(:num5), do: "\uE01F"
  defp key_code(:num6), do: "\uE020"
  defp key_code(:num7), do: "\uE021"
  defp key_code(:num8), do: "\uE022"
  defp key_code(:num9), do: "\uE023"
  defp key_code(:multiply), do: "\uE024"
  defp key_code(:add), do: "\uE025"
  defp key_code(:seperator), do: "\uE026"
  defp key_code(:subtract), do: "\uE027"
  defp key_code(:decimal), do: "\uE028"
  defp key_code(:divide), do: "\uE029"
  defp key_code(:command), do: "\uE03D"
  defp key_code(char) when is_binary(char), do: char
end
