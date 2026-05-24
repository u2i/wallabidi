defmodule Wallabidi.Remote.Driver.Orchestrator do
  @moduledoc false

  # Generic Driver-callback flows parameterised by a `Driver.Spec`.
  #
  # Each function takes the spec + the same args the Driver-behaviour
  # callback would, and consults the spec's dimension modules
  # (`spec.browser`, `spec.wire_protocol`) for the variable bits.
  #
  # SPIKE SCOPE: only `click/2`. If this works without leakage we'll
  # grow the orchestrator to absorb the other Driver callbacks.

  import Wallabidi.Driver.LogChecker

  alias Wallabidi.{Element, Session}
  alias Wallabidi.Remote.Driver.Spec

  @doc """
  Click an element, routing through the spec's wire_protocol and
  respecting the browser's `click_strategy` and `wraps_interactions_in_log_check?`.
  """
  @spec click(Spec.t(), Element.t()) :: {:ok, term} | {:error, term}
  def click(%Spec{} = spec, %Element{} = element) do
    session = Element.root_session(element)
    flow = fn -> do_click(spec, session, element) end

    if spec.browser.wraps_interactions_in_log_check?() do
      check_logs!(session, flow)
    else
      flow.()
    end
  end

  defp do_click(%Spec{browser: browser} = spec, session, element) do
    case browser.click_strategy() do
      :simple ->
        spec.wire_protocol.simple_click(session, element)

      :classified ->
        case spec.wire_protocol.classified_click(session, element) do
          {:ok, _classification, :ready} ->
            {:ok, nil}

          {:ok, classification, :timeout} when classification in ["navigate", "full_page"] ->
            # data-phx-link=redirect / JS.navigate-classified clicks raise
            # NavigationTimeoutError on page_ready timeout — those tests
            # explicitly catch the error.
            raise_navigation_timeout(spec, session, 5_000)

          {:ok, "patch", :timeout} ->
            # Patch-classified timeout: caller's assert_has retries will
            # take it from here. ChromeCDP additionally polls current_url
            # to ride out a slow LV handle_event before returning.
            if spec.patch_url_fallback? do
              _ = await_url_change_or_load(spec, session, 10_000)
            end

            {:ok, nil}

          {:ok, _classification, :timeout} ->
            {:ok, nil}

          err ->
            err
        end
    end
  end

  defp raise_navigation_timeout(%Spec{} = spec, session, timeout_ms) do
    post =
      case spec.wire_protocol.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    raise Wallabidi.NavigationTimeoutError, %{
      from: nil,
      to: post,
      timeout_ms: timeout_ms,
      page_state: :unknown,
      page_state_history: []
    }
  end

  defp await_url_change_or_load(%Spec{} = spec, %Session{} = session, timeout_ms) do
    pre_url =
      case spec.wire_protocol.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_url(spec, session, pre_url, deadline)
  end

  defp poll_url(%Spec{} = spec, session, pre_url, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :timeout
    else
      case spec.wire_protocol.current_url(session) do
        {:ok, url} when url != pre_url and url != "" ->
          :ok

        _ ->
          Process.sleep(50)
          poll_url(spec, session, pre_url, deadline)
      end
    end
  end
end
