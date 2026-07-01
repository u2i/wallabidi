defmodule Wallabidi.Integration.Feature.AutomaticScreenshotTest do
  use ExUnit.Case
  @moduletag :headless
  # Each test spawns inner ExUnit suites that themselves start fresh
  # browser sessions, then assert screenshots were taken on failure.
  # On Chrome BiDi this exposes a chromium-bidi quirk where the second
  # session's session.subscribe occasionally times out (the Mapper
  # serializes commands and the inner-test screenshot capture races
  # against subscribe). The screenshot mechanism itself is covered by
  # the Chrome CDP run.
  @moduletag :bidi_unstable

  alias ExUnit.CaptureIO

  describe "import Feature" do
    test "feature takes a screenshot on failure for each open wallabidi session" do
      defmodule ImportFeature.FailureWithMultipleSessionsTest do
        use ExUnit.Case
        import Wallabidi.Feature

        setup do
          Wallabidi.SettingsTestHelpers.ensure_setting_is_reset(
            :wallabidi,
            :screenshot_on_failure
          )

          Application.put_env(:wallabidi, :screenshot_on_failure, true)

          :ok
        end

        feature "fails" do
          {:ok, _} = Wallabidi.start_session()
          {:ok, _} = Wallabidi.start_session()

          assert false
        end
      end

      configure_and_reload_on_exit(colors: [enabled: false])

      output =
        CaptureIO.capture_io(fn ->
          assert ExUnit.run() == %{failures: 1, skipped: 0, total: 1, excluded: 0}
        end)

      assert (output =~ "1 feature" and output =~ "1 failure") or output =~ "Failed: 1 feature"
      assert screenshot_taken_count(output) == 2
    end
  end

  describe "use Feature" do
    test "feature takes a screenshot on failure for each open wallabidi session" do
      defmodule UseFeature.FailureWithMultipleSessionsTest do
        use ExUnit.Case
        use Wallabidi.Feature

        @sessions 2
        feature "fails", %{sessions: _sessions} do
          Wallabidi.SettingsTestHelpers.ensure_setting_is_reset(
            :wallabidi,
            :screenshot_on_failure
          )

          Application.put_env(:wallabidi, :screenshot_on_failure, true)

          assert false
        end
      end

      configure_and_reload_on_exit(colors: [enabled: false])

      output =
        CaptureIO.capture_io(fn ->
          assert ExUnit.run() == %{failures: 1, skipped: 0, total: 1, excluded: 0}
        end)

      assert (output =~ "1 feature" and output =~ "1 failure") or output =~ "Failed: 1 feature"
      assert screenshot_taken_count(output) == 2
    end
  end

  defp configure_and_reload_on_exit(opts) do
    old_opts = ExUnit.configuration()
    ExUnit.configure(opts)

    on_exit(fn -> ExUnit.configure(old_opts) end)
  end

  defp screenshot_taken_count(output) do
    ~r{- file:///}
    |> Regex.scan(output)
    |> length()
  end
end
