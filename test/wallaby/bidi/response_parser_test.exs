defmodule Wallaby.BiDi.ResponseParserTest do
  use ExUnit.Case, async: true

  alias Wallaby.BiDi.ResponseParser

  describe "extract_value/1" do
    test "extracts string" do
      assert {:ok, "hello"} =
               ResponseParser.extract_value(%{"type" => "string", "value" => "hello"})
    end

    test "extracts number" do
      assert {:ok, 42} = ResponseParser.extract_value(%{"type" => "number", "value" => 42})
    end

    test "extracts boolean" do
      assert {:ok, true} = ResponseParser.extract_value(%{"type" => "boolean", "value" => true})
      assert {:ok, false} = ResponseParser.extract_value(%{"type" => "boolean", "value" => false})
    end

    test "extracts null" do
      assert {:ok, nil} = ResponseParser.extract_value(%{"type" => "null"})
    end

    test "extracts undefined as nil" do
      assert {:ok, nil} = ResponseParser.extract_value(%{"type" => "undefined"})
    end

    test "extracts array" do
      assert {:ok, ["a", "b"]} =
               ResponseParser.extract_value(%{
                 "type" => "array",
                 "value" => [
                   %{"type" => "string", "value" => "a"},
                   %{"type" => "string", "value" => "b"}
                 ]
               })
    end

    test "extracts nested result wrapper" do
      assert {:ok, "inner"} =
               ResponseParser.extract_value(%{
                 "result" => %{"type" => "string", "value" => "inner"}
               })
    end

    test "extracts node with shared ID" do
      node = %{"type" => "node", "sharedId" => "node-abc", "value" => %{}}

      assert {:ok, {:node, "node-abc", ^node}} = ResponseParser.extract_value(node)
    end

    test "returns error for unexpected values" do
      assert {:error, {:unexpected_value, _}} =
               ResponseParser.extract_value(%{"something" => "unknown"})
    end
  end

  describe "extract_nodes/1" do
    test "extracts nodes from locateNodes response" do
      response = %{
        "nodes" => [
          %{"sharedId" => "n1", "type" => "node", "value" => %{}},
          %{"sharedId" => "n2", "type" => "node", "value" => %{}}
        ]
      }

      assert {:ok, [{"n1", _}, {"n2", _}]} = ResponseParser.extract_nodes(response)
    end

    test "returns error for unexpected format" do
      assert {:error, _} = ResponseParser.extract_nodes(%{"unexpected" => true})
    end
  end

  describe "extract_context/1" do
    test "extracts first context from getTree response" do
      response = %{
        "contexts" => [
          %{"context" => "ctx-abc", "url" => "about:blank"}
        ]
      }

      assert {:ok, "ctx-abc"} = ResponseParser.extract_context(response)
    end

    test "returns error for empty contexts" do
      assert {:error, _} = ResponseParser.extract_context(%{"unexpected" => true})
    end
  end

  describe "extract_all_contexts/1" do
    test "extracts all context IDs" do
      response = %{
        "contexts" => [
          %{"context" => "ctx-1"},
          %{"context" => "ctx-2"}
        ]
      }

      assert {:ok, ["ctx-1", "ctx-2"]} = ResponseParser.extract_all_contexts(response)
    end
  end

  describe "extract_screenshot/1" do
    test "decodes base64 screenshot data" do
      encoded = Base.encode64("fake-png-data")
      assert {:ok, "fake-png-data"} = ResponseParser.extract_screenshot(%{"data" => encoded})
    end
  end

  describe "extract_cookies/1" do
    test "normalizes cookie format" do
      response = %{
        "cookies" => [
          %{
            "name" => "token",
            "value" => %{"value" => "abc123"},
            "domain" => "localhost",
            "path" => "/",
            "secure" => false,
            "httpOnly" => false,
            "expiry" => nil
          }
        ]
      }

      assert {:ok, [cookie]} = ResponseParser.extract_cookies(response)
      assert cookie["name"] == "token"
      assert cookie["value"] == "abc123"
    end
  end

  describe "cast_elements/2" do
    test "creates Element structs from node tuples" do
      parent = %Wallaby.Session{
        session_url: "http://localhost:9515/session/123",
        driver: Wallaby.Chrome
      }

      nodes = [
        {"shared-1", %{"sharedId" => "shared-1", "value" => %{"backendNodeId" => 42}}},
        {"shared-2", %{"sharedId" => "shared-2", "value" => %{}}}
      ]

      elements = ResponseParser.cast_elements(parent, nodes)
      assert length(elements) == 2

      [el1, el2] = elements
      assert el1.bidi_shared_id == "shared-1"
      assert el1.id == "42"
      assert el1.driver == Wallaby.Chrome
      assert el2.bidi_shared_id == "shared-2"
    end
  end

  describe "check_error/1" do
    test "maps stale element reference" do
      assert {:error, :stale_reference} =
               ResponseParser.check_error({:error, {"stale element reference", "msg"}})
    end

    test "maps invalid selector" do
      assert {:error, :invalid_selector} =
               ResponseParser.check_error({:error, {"invalid selector", "msg"}})
    end

    test "maps element click intercepted to obscured" do
      assert {:error, :obscured} =
               ResponseParser.check_error({:error, {"element click intercepted", "msg"}})
    end

    test "passes through ok values" do
      assert {:ok, "data"} = ResponseParser.check_error({:ok, "data"})
    end

    test "passes through unknown errors" do
      assert {:error, {"unknown", "msg"}} =
               ResponseParser.check_error({:error, {"unknown", "msg"}})
    end
  end
end
