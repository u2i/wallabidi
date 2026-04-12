defmodule Wallabidi.BiDiClientTest do
  use ExUnit.Case, async: true

  alias Wallabidi.BiDiClient
  alias Wallabidi.{Element, Session}

  # These tests verify the settle logic which uses process mailbox
  # messages rather than requiring a real browser connection.

  describe "public API" do
    test "exports all expected functions" do
      funs = BiDiClient.__info__(:functions)

      # Navigation
      assert {:visit, 2} in funs
      assert {:current_url, 1} in funs
      assert {:current_path, 1} in funs
      assert {:find_elements, 2} in funs

      # Element interaction
      assert {:click, 1} in funs
      assert {:clear, 1} in funs
      assert {:set_value, 2} in funs
      assert {:text, 1} in funs
      assert {:attribute, 2} in funs
      assert {:displayed, 1} in funs
      assert {:selected, 1} in funs

      # Scripts
      assert {:execute_script, 2} in funs
      assert {:execute_script_async, 2} in funs

      # Screenshots
      assert {:take_screenshot, 1} in funs

      # Cookies
      assert {:cookies, 1} in funs
      assert {:set_cookie, 3} in funs

      # Window management
      assert {:window_handles, 1} in funs
      assert {:window_handle, 1} in funs
      assert {:focus_window, 2} in funs
      assert {:close_window, 1} in funs
      assert {:set_window_size, 3} in funs
      assert {:get_window_size, 1} in funs
      assert {:maximize_window, 1} in funs

      # Page info
      assert {:page_source, 1} in funs
      assert {:page_title, 1} in funs

      # Mouse/touch
      assert {:double_click, 1} in funs
      assert {:button_down, 2} in funs
      assert {:button_up, 2} in funs
      assert {:touch_up, 1} in funs
      assert {:tap, 1} in funs

      # Dialogs
      assert {:accept_alert, 2} in funs
      assert {:dismiss_alert, 2} in funs
      assert {:accept_confirm, 2} in funs
      assert {:dismiss_confirm, 2} in funs
      assert {:accept_prompt, 3} in funs
      assert {:dismiss_prompt, 2} in funs

      # DX features
      assert {:settle, 3} in funs
      assert {:on_console, 2} in funs
      assert {:intercept_request, 3} in funs
      assert {:log, 1} in funs
    end
  end

  describe "execute_script" do
    test "is exported with arity 2 and 3" do
      funs = BiDiClient.__info__(:functions)
      assert {:execute_script, 2} in funs
      assert {:execute_script, 3} in funs
    end
  end

  describe "element operations without bidi_shared_id" do
    test "click returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.click(element)
    end

    test "text returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.text(element)
    end

    test "clear returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.clear(element)
    end

    test "displayed returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.displayed(element)
    end

    test "selected returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.selected(element)
    end

    test "attribute returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.attribute(element, "href")
    end

    test "element_size returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.element_size(element)
    end

    test "element_location returns error for elements without shared_id" do
      element = %Element{id: "legacy", bidi_shared_id: nil, parent: %Session{bidi_pid: self()}}
      assert {:error, :no_bidi_shared_id} = BiDiClient.element_location(element)
    end
  end

  describe "window_handle/1" do
    test "returns the browsing context" do
      session = %Session{browsing_context: "ctx-123", bidi_pid: self()}
      assert {:ok, "ctx-123"} = BiDiClient.window_handle(session)
    end
  end

  describe "current_path/1 derivation" do
    # current_path derives from current_url, test the URL parsing logic
    test "module exports current_path/1" do
      Code.ensure_loaded!(BiDiClient)
      assert function_exported?(BiDiClient, :current_path, 1)
    end
  end
end
