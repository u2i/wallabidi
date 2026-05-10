defmodule Wallabidi.QueryError do
  defexception [:message]

  def exception(error) do
    %__MODULE__{message: error}
  end
end

defmodule Wallabidi.ExpectationNotMetError do
  defexception [:message]
end

defmodule Wallabidi.BadMetadataError do
  defexception [:message]
end

defmodule Wallabidi.NoBaseUrlError do
  defexception [:message]

  def exception(relative_path) do
    msg = """
    You called visit with #{relative_path}, but did not set a base_url.
    Set this in config/test.exs or in test/test_helper.exs:

      Application.put_env(:wallabidi, :base_url, "http://localhost:4001")

    If using Phoenix, you can use the url from your endpoint:

      Application.put_env(:wallabidi, :base_url, YourApplication.Endpoint.url)
    """

    %__MODULE__{message: msg}
  end
end

defmodule Wallabidi.JSError do
  defexception [:message]

  def exception(js_error) do
    msg = """
    There was an uncaught JavaScript error:

    #{js_error}
    """

    %__MODULE__{message: msg}
  end
end

defmodule Wallabidi.StaleReferenceError do
  defexception [:message]

  def exception(_) do
    msg = """
    The element you are trying to reference is stale or no longer attached to the
    DOM. The most likely reason is that it has been removed with JavaScript.

    You can typically solve this problem by using `find` to block until the DOM is in a
    stable state.
    """

    %__MODULE__{message: msg}
  end
end

defmodule Wallabidi.CookieError do
  defexception [:message]

  def exception(_) do
    msg = """
    The cookie you are trying to set has no domain.

    You're most likely seeing this error because you're trying to set a cookie before
    you have visited a page. You can fix this issue by calling `visit/1`
    before you call `set_cookie/3` or `set_cookie/4`.
    """

    %__MODULE__{message: msg}
  end
end

defmodule Wallabidi.DriverError do
  defexception [:message]

  def not_supported(operation) do
    %__MODULE__{
      message:
        "#{operation} is not supported by the LiveView driver. " <>
          "Tag this test with @tag :browser to run it with a browser driver."
    }
  end
end

defmodule Wallabidi.NavigationTimeoutError do
  defexception [:message]

  def exception(%{from: from, to: to, timeout_ms: timeout} = ctx) do
    state_section =
      case ctx[:page_state] do
        nil ->
          ""

        state ->
          history = ctx[:page_state_history] || []
          history_lines = Enum.map_join(history, "\n      ", &format_history_entry/1)

          """


          Page-ready state at timeout: #{inspect(state)}
          Recent transitions:
              #{history_lines}
          """
      end

    msg = """
    Navigation from #{inspect(from)} to #{inspect(to)} did not complete within #{timeout}ms.

    The click was classified as a LiveView navigation (data-phx-link=redirect or a JS.navigate
    command), but the browser URL did not change and no new LiveView mounted before the deadline.

    Common causes:
      * The destination route's connected mount is slower than the deadline.
      * LiveView's click handler never intercepted the synthetic click — try
        verifying that the click actually dispatched on the anchor element.
      * The click was classified wrong (see `W.classify` in priv/wallabidi.js).
    #{state_section}
    """

    %__MODULE__{message: msg}
  end

  defp format_history_entry(%{state: state, doc_id: doc, reason: reason, at_ms: ms}) do
    "+#{ms}ms  #{state}  doc=#{String.slice(doc || "?", 0, 12)}  reason=#{reason}"
  end
end

defmodule Wallabidi.DependencyError do
  defexception [:message]

  @type t :: %__MODULE__{
          message: String.t()
        }

  def exception(msg) do
    %__MODULE__{message: msg}
  end
end
