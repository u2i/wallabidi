defmodule Wallabidi.Remote.BiDi.CommandsTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Remote.BiDi.Commands

  describe "perform_actions/2" do
    test "builds input.performActions command" do
      actions = [%{type: "key", id: "keyboard", actions: []}]

      assert {"input.performActions", params} = Commands.perform_actions("ctx-1", actions)
      assert params.context == "ctx-1"
      assert params.actions == actions
    end
  end

  describe "capture_screenshot/1" do
    test "builds browsingContext.captureScreenshot command" do
      assert {"browsingContext.captureScreenshot", %{context: "ctx-1"}} =
               Commands.capture_screenshot("ctx-1")
    end
  end

  describe "handle_user_prompt/3" do
    test "builds accept command" do
      assert {"browsingContext.handleUserPrompt", params} =
               Commands.handle_user_prompt("ctx-1", true)

      assert params.context == "ctx-1"
      assert params.accept == true
      refute Map.has_key?(params, :userText)
    end

    test "builds accept with user text" do
      assert {"browsingContext.handleUserPrompt", params} =
               Commands.handle_user_prompt("ctx-1", true, "hello")

      assert params.userText == "hello"
    end
  end

  describe "set_viewport/3" do
    test "builds browsingContext.setViewport command" do
      assert {"browsingContext.setViewport", params} = Commands.set_viewport("ctx-1", 1024, 768)
      assert params.viewport == %{width: 1024, height: 768}
    end
  end

  describe "subscribe/1" do
    test "builds session.subscribe command" do
      assert {"session.subscribe", params} = Commands.subscribe(["log.entryAdded"])
      assert params.events == ["log.entryAdded"]
      refute Map.has_key?(params, :contexts)
    end

    test "supports context filter" do
      assert {"session.subscribe", params} =
               Commands.subscribe(["log.entryAdded"], ["ctx-1"])

      assert params.contexts == ["ctx-1"]
    end
  end

  describe "get_cookies/1" do
    test "builds storage.getCookies command" do
      assert {"storage.getCookies", %{}} = Commands.get_cookies()
    end
  end

  describe "set_cookie/2" do
    test "builds storage.setCookie command" do
      cookie = %{name: "token", value: %{type: "string", value: "abc"}}

      assert {"storage.setCookie", params} = Commands.set_cookie(cookie)
      assert params.cookie == cookie
    end
  end

  describe "key_type_actions/1" do
    test "builds key actions for string" do
      [action_source] = Commands.key_type_actions("ab")
      assert action_source.type == "key"

      assert [
               %{type: "keyDown", value: "a"},
               %{type: "keyUp", value: "a"},
               %{type: "keyDown", value: "b"},
               %{type: "keyUp", value: "b"}
             ] = action_source.actions
    end

    test "builds key actions for atom keys" do
      [action_source] = Commands.key_type_actions([:enter])
      [down, up] = action_source.actions
      assert down.type == "keyDown"
      assert down.value == "\uE007"
      assert up.type == "keyUp"
    end

    test "handles mixed keys and strings" do
      [action_source] = Commands.key_type_actions(["x", :tab])
      assert length(action_source.actions) == 4
    end
  end

  describe "touch actions" do
    test "touch_down_actions builds touch down sequence" do
      [source] = Commands.touch_down_actions(100, 200)
      assert source.parameters == %{pointerType: "touch"}
      assert length(source.actions) == 2
    end

    test "touch_up_actions builds touch up" do
      [source] = Commands.touch_up_actions()
      assert [%{type: "pointerUp"}] = source.actions
    end

    test "touch_tap_element_actions builds tap on element" do
      [source] = Commands.touch_tap_element_actions("elem-1")
      assert length(source.actions) == 3
    end
  end
end
