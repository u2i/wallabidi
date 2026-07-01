defmodule Wallabidi.Test.AwaitMonitor do
  @moduledoc """
  Detects event-driven-await regressions per test.

  Wallabidi's interactions are event-driven: `visit`, `click`, `fill_in`,
  `assert_has`, `await_patch` resolve when a browser event fires
  (`onPatchEnd`, a `MutationObserver` hit, a page-ready notification), not
  by polling or sleeping. When the event mechanism silently breaks, an
  await *falls back to its timeout* and the test often still passes — a
  later retry happens to find the element — so the regression hides behind
  a green checkmark.

  This module catches that. Event-driven await operations call
  `record_timeout/1` on the branch where a fire was expected but the
  deadline elapsed. The `Wallabidi.Feature` setup drains the current test's
  records in an `on_exit` and fails the test if any are present — so "this
  test only passed by timing out" surfaces as a real failure, in place.

  Timeouts that are *expected* (waiting for absence: `refute_has`,
  visible?: false) must NOT be recorded — those legitimately wait out the
  budget.

  ## Lifecycle

  Enabled only in the test environment, by calling `setup/0` from
  `test_helper.exs`. Until then (and in production), `record_timeout/1` and
  `drain/1` are cheap no-ops — the `lib/` await code can call
  `record_timeout/1` unconditionally with zero production cost or coupling.

  Records are keyed by the **test process pid** (await ops run in the test
  process, so `self()` is the test). `Wallabidi.Feature` captures that pid
  at setup and passes it to `drain/1` from `on_exit` (which runs in a
  *different* process).

  ## Mode

  `WALLABIDI_AWAIT_MODE=warn` records and reports but does not fail — for a
  validation pass before the detector gates CI. Default is `:raise`.
  """

  @table __MODULE__

  @doc "Create the ETS table. Call once from test_helper.exs (test env only)."
  def setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag, write_concurrency: true])
    end

    :ok
  end

  @doc "Whether the monitor is active (table exists). False in production."
  def enabled?, do: :ets.info(@table) != :undefined

  @doc ":raise (default) or :warn, from WALLABIDI_AWAIT_MODE."
  def mode do
    case System.get_env("WALLABIDI_AWAIT_MODE") do
      "warn" -> :warn
      _ -> :raise
    end
  end

  @doc """
  Record that an event-driven await `op` fell back to its timeout in the
  current test process. No-op when the monitor isn't enabled.

  `op` is a short term identifying the operation, e.g. `:patch`,
  `:page_ready`, `:selector`, `{:selector, query_desc}`.
  """
  def record_timeout(op) do
    if enabled?() do
      :ets.insert(@table, {self(), op})
    end

    :ok
  end

  @doc """
  Return and clear the recorded timeouts for `test_pid`. Returns `[]` when
  the monitor isn't enabled or the test had none.
  """
  def drain(test_pid) do
    if enabled?() do
      ops = :ets.lookup(@table, test_pid) |> Enum.map(fn {_pid, op} -> op end)
      :ets.delete(@table, test_pid)
      ops
    else
      []
    end
  end

  @doc """
  Called from a test's `on_exit`. Raises (or warns) if the test recorded
  event-driven-await timeouts. No-op when not enabled, no timeouts were
  recorded, or the test opted out.

  `context` is the ExUnit test context — used for the test name and to
  honor the `@tag :expected_await_timeout` opt-out, for tests where an
  await-timeout is *structural* (e.g. a fake/non-LiveView page that has no
  real event to fire, so the await legitimately waits out its budget).
  Always drains the records (so they don't leak into the next test on a
  reused pid), even when opted out.
  """
  def check!(test_pid, context \\ %{}) do
    ops = drain(test_pid)
    test_name = Map.get(context, :test)

    cond do
      ops == [] ->
        :ok

      Map.get(context, :expected_await_timeout, false) ->
        # Opted out: timeouts are structural to this test.
        :ok

      true ->
        report(ops, test_name)
    end
  end

  defp report(ops, test_name) do
    message = format(ops, test_name)

    case mode() do
      :warn -> IO.puts(:stderr, "[wallabidi] " <> message)
      :raise -> raise message
    end
  end

  defp format(ops, test_name) do
    grouped =
      ops
      |> Enum.frequencies()
      |> Enum.map_join("\n", fn {op, n} -> "  - #{inspect(op)}#{count(n)}" end)

    where = if test_name, do: " in #{inspect(test_name)}", else: ""

    """
    Event-driven await(s) fell back to a timeout#{where}.

    These operations waited out their full timeout instead of resolving on
    an event (onPatchEnd / MutationObserver / page-ready). The test may
    still have passed via a retry, masking a broken event-driven path —
    that's the regression this guards against.

    #{grouped}

    If a timeout is legitimately expected here (waiting for absence, e.g.
    refute_has), the await should be recorded as expected and not flagged —
    fix the emission, not this assertion. To downgrade to a warning during
    investigation: WALLABIDI_AWAIT_MODE=warn.
    """
  end

  defp count(1), do: ""
  defp count(n), do: " (#{n}×)"
end
