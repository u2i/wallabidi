defmodule Wallabidi.Driver.LogCheckerTest do
  use ExUnit.Case, async: true

  alias Wallabidi.Driver.LogChecker

  defmodule FakeDriver do
    def parse_log(%{"level" => "SEVERE", "source" => "javascript", "message" => msg}) do
      send(self(), {:js_error, msg})
    end

    def parse_log(%{"level" => "INFO", "source" => "console-api", "message" => msg}) do
      send(self(), {:console_log, msg})
    end

    def parse_log(_), do: nil
  end

  defp make_session do
    %{driver: FakeDriver, session_url: "test://session/1"}
  end

  describe "check_logs!/2" do
    test "returns the value from the function" do
      session = make_session()
      result = LogChecker.check_logs!(session, fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "drains log events from mailbox" do
      session = make_session()

      # Simulate a BiDi log event arriving in the mailbox
      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "hello world",
             "source" => %{"url" => "http://localhost/page.js"},
             "lineNumber" => 10,
             "columnNumber" => 5
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert_received {:console_log, "http://localhost/page.js 10:5 hello world"}
    end

    test "translates error level to SEVERE" do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "error",
             "type" => "javascript",
             "text" => "ReferenceError: x is not defined",
             "source" => %{"url" => "http://localhost/app.js"},
             "lineNumber" => 1,
             "columnNumber" => 0
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert_received {:js_error, "http://localhost/app.js 1:0 ReferenceError: x is not defined"}
    end

    test "filters out chromedriver mapper noise" do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "Launching Mapper instance with selfTargetId: ABC123",
             "source" => %{}
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      refute_received {:console_log, _}
    end

    test "processes multiple events in order" do
      session = make_session()

      for i <- 1..3 do
        send(
          self(),
          {:bidi_event, "log.entryAdded",
           %{
             "params" => %{
               "level" => "info",
               "type" => "console",
               "text" => "msg #{i}",
               "source" => %{"url" => "http://localhost/test.js"},
               "lineNumber" => i,
               "columnNumber" => 0
             }
           }}
        )
      end

      LogChecker.check_logs!(session, fn -> :ok end)

      assert_received {:console_log, "http://localhost/test.js 1:0 msg 1"}
      assert_received {:console_log, "http://localhost/test.js 2:0 msg 2"}
      assert_received {:console_log, "http://localhost/test.js 3:0 msg 3"}
    end

    test "handles events with no URL" do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "inline log",
             "source" => %{}
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert_received {:console_log, "unknown 0:0 inline log"}
    end

    test "does nothing when no events are buffered" do
      session = make_session()
      result = LogChecker.check_logs!(session, fn -> :done end)
      assert result == :done
      refute_received _
    end
  end
end
