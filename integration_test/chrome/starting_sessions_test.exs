defmodule Wallabidi.Integration.Chrome.StartingSessionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  import Wallabidi.SettingsTestHelpers
  import Wallabidi.TestSupport.ApplicationControl
  import Wallabidi.TestSupport.TestScriptUtils
  import Wallabidi.TestSupport.TestWorkspace

  alias Wallabidi.Chrome
  alias Wallabidi.TestSupport.Chrome.ChromeTestScript
  alias Wallabidi.TestSupport.TestWorkspace

  @moduletag :capture_log

  # These tests stop/restart wallabidi with custom chromedriver configs.
  # They only make sense with a local chromedriver — skip when using
  # a remote URL (Docker, Compose, CI with remote chrome).
  if !match?({:ok, _}, Wallabidi.Chrome.find_chromedriver_executable()) or
       Application.get_env(:wallabidi, :chromedriver, []) |> Keyword.has_key?(:remote_url) do
    @moduletag :skip
  end

  setup [:restart_wallabidi_on_exit!, :stop_wallabidi]

  setup do
    [workspace_path: mkdir!()]
  end

  test "works when chromedriver starts immediately", %{workspace_path: workspace_path} do
    {:ok, chromedriver_path} = Chrome.find_chromedriver_executable()

    test_script_path =
      chromedriver_path
      |> ChromeTestScript.build_chromedriver_wrapper_script()
      |> write_test_script!(workspace_path)

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert :ok = Application.start(:wallabidi)

    assert {:ok, _session} = Wallabidi.start_session()
  end

  test "starting a session boots chromedriver with the default options", %{
    workspace_path: workspace_path
  } do
    {:ok, chromedriver_path} = Chrome.find_chromedriver_executable()

    test_script_path =
      chromedriver_path
      |> ChromeTestScript.build_chromedriver_wrapper_script()
      |> write_test_script!(workspace_path)

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert :ok = Application.start(:wallabidi)

    assert {:ok, _session} = Wallabidi.start_session()

    assert [invocation] = ChromeTestScript.get_invocations(test_script_path) |> Enum.take(-1)

    assert {switches, [^chromedriver_path]} =
             invocation
             |> String.split()
             |> OptionParser.parse!(switches: [], allow_nonexistent_atoms: true)

    switches
    |> assert_switch(:port, fn port -> String.to_integer(port) > 0 end)
    |> assert_switch(:log_level, &match?("OFF", &1))
    |> assert_no_remaining_switches()
  end

  test "does not raise a connection refused error if chromedriver is slow to startup" do
    test_script_path =
      TestWorkspace.mkdir!()
      |> write_chrome_wrapper_script!(startup_delay: :timer.seconds(1))

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert :ok = Application.start(:wallabidi)

    assert {:ok, _session} = Wallabidi.start_session()
  end

  test "raises a RuntimeError if chromedriver isn't ready before the startup timeout" do
    test_script_path =
      TestWorkspace.mkdir!()
      |> write_chrome_wrapper_script!(startup_delay: :timer.seconds(12))

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert :ok = Application.start(:wallabidi)

    assert_raise RuntimeError, ~r/timeout waiting for chromedriver to be ready/i, fn ->
      Wallabidi.start_session(readiness_timeout: 500)
    end
  end

  test "application does not start when chromedriver version < 2.30", %{
    workspace_path: workspace_path
  } do
    test_script_path =
      ChromeTestScript.build_chromedriver_version_mock_script(version: "2.29")
      |> write_test_script!(workspace_path)

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert {:error, _} = Application.start(:wallabidi)
  end

  test "application starts when chromedriver version >= 2.30", %{workspace_path: workspace_path} do
    chromedriver_test_script_path =
      ChromeTestScript.build_chromedriver_version_mock_script(version: "2.30")
      |> write_test_script!(workspace_path)

    chrome_test_script_path =
      ChromeTestScript.build_chrome_version_mock_script(version: "2.30")
      |> write_test_script!(workspace_path)

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: chromedriver_test_script_path)
    Application.put_env(:wallabidi, :chromedriver, binary: chrome_test_script_path)

    log =
      capture_io(:stderr, fn ->
        assert :ok == Application.start(:wallabidi)
      end)

    assert log =~ "don't match"
  end

  test "application does not start when chrome version != chromedriver version", %{
    workspace_path: workspace_path
  } do
    chromedriver_test_script_path =
      ChromeTestScript.build_chromedriver_version_mock_script(version: "99.0.3945.36")
      |> write_test_script!(workspace_path)

    chrome_test_script_path =
      ChromeTestScript.build_chrome_version_mock_script(version: "101.0.3945.36")
      |> write_test_script!(workspace_path)

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: chromedriver_test_script_path)
    Application.put_env(:wallabidi, :chromedriver, binary: chrome_test_script_path)

    log =
      capture_io(:stderr, fn ->
        assert :ok == Application.start(:wallabidi)
      end)

    assert log =~ "don't match"
  end

  test "works with a path in the home directory" do
    test_script_path =
      "~/.wallabidi-tmp-%{random_string}"
      |> TestWorkspace.mkdir!()
      |> write_chrome_wrapper_script!()

    ensure_setting_is_reset(:wallabidi, :chromedriver)
    Application.put_env(:wallabidi, :chromedriver, path: test_script_path)

    assert :ok = Application.start(:wallabidi)

    assert {:ok, _session} = Wallabidi.start_session()

    assert test_script_path |> ChromeTestScript.get_invocations() |> Enum.any?()
  end

  test "fails to start when chromedriver path is configured incorrectly" do
    ensure_setting_is_reset(:wallabidi, :chromedriver)

    Application.put_env(:wallabidi, :chromedriver, path: "this-really-should-not-exist")

    assert {:error, _} = Application.start(:wallabidi)
  end

  defp write_chrome_wrapper_script!(base_dir, opts \\ []) do
    {:ok, chromedriver_path} = Chrome.find_chromedriver_executable()

    chromedriver_path
    |> ChromeTestScript.build_chromedriver_wrapper_script(opts)
    |> write_test_script!(base_dir)
  end
end
