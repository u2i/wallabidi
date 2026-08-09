defmodule Wallabidi.ConfigTest do
  use ExUnit.Case, async: false

  alias Wallabidi.Config

  setup do
    original_test = Application.get_env(:wallabidi, :test)
    original_base = Application.get_env(:wallabidi, :base_url)

    on_exit(fn ->
      restore(:test, original_test)
      restore(:base_url, original_base)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:wallabidi, key)
  defp restore(key, value), do: Application.put_env(:wallabidi, key, value)

  describe "get_test/2" do
    test "prefers the test namespace over the application's setting" do
      Application.put_env(:wallabidi, :base_url, "https://app.example.com")
      Application.put_env(:wallabidi, :test, base_url: "http://localhost:4002")

      assert Config.get(:base_url) == "https://app.example.com"
      assert Config.get_test(:base_url) == "http://localhost:4002"
    end

    test "falls back to the application's setting for unset keys" do
      Application.put_env(:wallabidi, :base_url, "https://app.example.com")
      Application.put_env(:wallabidi, :test, max_wait_time: 1_000)

      assert Config.get_test(:base_url) == "https://app.example.com"
    end

    test "falls back to the default when neither namespace sets the key" do
      Application.delete_env(:wallabidi, :base_url)
      Application.delete_env(:wallabidi, :test)

      assert Config.get_test(:base_url, "fallback") == "fallback"
    end
  end

  describe "get_for/3" do
    test "resolves against the test namespace for a test session" do
      Application.put_env(:wallabidi, :base_url, "https://app.example.com")
      Application.put_env(:wallabidi, :test, base_url: "http://localhost:4002")

      assert Config.get_for(%{test_session?: true}, :base_url) == "http://localhost:4002"
      assert Config.get_for(%{test_session?: false}, :base_url) == "https://app.example.com"
    end

    test "resolves against the application namespace when there is no session" do
      Application.put_env(:wallabidi, :base_url, "https://app.example.com")
      Application.put_env(:wallabidi, :test, base_url: "http://localhost:4002")

      assert Config.get_for(nil, :base_url) == "https://app.example.com"
    end
  end

  describe "test_config/0" do
    test "is empty when the namespace is unset" do
      Application.delete_env(:wallabidi, :test)
      assert Config.test_config() == []
    end

    test "tolerates a non-keyword value rather than crashing session start" do
      Application.put_env(:wallabidi, :test, :nonsense)
      assert Config.test_config() == []
    end
  end
end
