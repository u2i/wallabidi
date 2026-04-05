# credo:disable-for-this-file Credo.Check.Refactor.Apply
defmodule Wallabidi.Lightpanda do
  @moduledoc """
  The Lightpanda driver uses CDP (Chrome DevTools Protocol) to control
  the Lightpanda headless browser.

  ## Usage

  ```elixir
  config :wallabidi, driver: :lightpanda
  ```

  Requires the `lightpanda` hex package for binary management.

  ## Configuration

  ```elixir
  config :lightpanda,
    version: "0.2.8",
    default: [args: ~w(serve --host 127.0.0.1 --port 9222)]
  ```
  """

  use Supervisor

  @behaviour Wallabidi.Driver

  alias Wallabidi.{CDPClient, Session}
  alias Wallabidi.DependencyError
  alias Wallabidi.Driver.SessionLifecycle

  # --- Supervisor ---

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @lightpanda_server Module.concat([Lightpanda, Server])

  @impl Supervisor
  def init(_) do
    children =
      if remote_url() do
        []
      else
        [
          {@lightpanda_server, [name: Wallabidi.Lightpanda.Server]}
        ]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Validation ---

  @doc false
  def validate do
    cond do
      remote_url() ->
        :ok

      lightpanda_available?() ->
        :ok

      true ->
        {:error,
         DependencyError.exception(
           "Wallabidi can't find lightpanda. Install it with: mix lightpanda.install"
         )}
    end
  end

  # --- Session lifecycle ---

  @impl true
  def start_session(opts \\ []) do
    ws_url =
      if remote_url() do
        remote_url()
      else
        apply(@lightpanda_server, :ws_url, [Wallabidi.Lightpanda.Server])
      end

    with {:ok, pid} <- CDPClient.connect(ws_url),
         {:ok, %{target_id: target_id, session_id: session_id}} <-
           CDPClient.create_session(pid) do
      unique_id = "lp-#{System.unique_integer([:positive])}"

      session = %Session{
        id: unique_id,
        session_url: "cdp://#{unique_id}",
        url: "cdp://#{unique_id}",
        driver: __MODULE__,
        server: __MODULE__,
        bidi_pid: pid,
        browsing_context: session_id,
        capabilities: %{target_id: target_id}
      }

      if window_size = Keyword.get(opts, :window_size) do
        {:ok, _} = set_window_size(session, window_size[:width], window_size[:height])
      end

      {:ok, session}
    end
  end

  @impl true
  def end_session(session) do
    # Just close the WebSocket — Lightpanda automatically cleans up the
    # target and thread when the client disconnects. Skipping closeTarget
    # avoids hangs when Lightpanda is under load.
    SessionLifecycle.teardown(session)
  end

  # --- Delegation to CDPClient ---

  @impl true
  def visit(session, url), do: CDPClient.visit(session, url)

  @impl true
  def current_url(session), do: CDPClient.current_url(session)

  @impl true
  def current_path(session) do
    case current_url(session) do
      {:ok, url} -> {:ok, URI.parse(url).path || "/"}
      error -> error
    end
  end

  @impl true
  def find_elements(parent, query), do: CDPClient.find_elements(parent, query)

  @impl true
  def click(element), do: CDPClient.click(element)

  @impl true
  def text(element), do: CDPClient.text(element)

  @impl true
  def attribute(element, name), do: CDPClient.attribute(element, name)

  @impl true
  def displayed(element), do: CDPClient.displayed(element)

  @impl true
  def selected(element), do: CDPClient.selected(element)

  @impl true
  def set_value(element, value), do: CDPClient.set_value(element, value)

  @impl true
  def clear(element, _opts \\ []), do: CDPClient.clear(element)

  @impl true
  def page_source(session), do: CDPClient.page_source(session)

  @impl true
  def page_title(session), do: CDPClient.page_title(session)

  @impl true
  def execute_script(session, script, args), do: CDPClient.execute_script(session, script, args)

  @impl true
  def execute_script_async(session, script, args),
    do: CDPClient.execute_script_async(session, script, args)

  @impl true
  def send_keys(session_or_element, keys), do: CDPClient.send_keys(session_or_element, keys)

  @impl true
  def cookies(session), do: CDPClient.cookies(session)

  @impl true
  def set_cookie(session, name, value), do: CDPClient.set_cookie(session, name, value)

  @impl true
  def set_cookie(session, name, value, attrs),
    do: CDPClient.set_cookie(session, name, value, attrs)

  @impl true
  def take_screenshot(session), do: CDPClient.take_screenshot(session)

  def blank_page?(session) do
    case current_url(session) do
      {:ok, url} -> url in ["data:,", "about:blank", ""]
      _ -> false
    end
  end

  @impl true
  def get_window_size(session), do: CDPClient.get_window_size(session)

  @impl true
  def set_window_size(session, w, h), do: CDPClient.set_window_size(session, w, h)

  # --- Stubs for operations not yet implemented ---

  @impl true
  def accept_alert(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def accept_confirm(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def accept_prompt(session, _text, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def dismiss_confirm(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def dismiss_prompt(session, fun) do
    result = fun.(session)
    {:ok, [result]}
  end

  @impl true
  def window_handle(_), do: {:ok, "main"}

  @impl true
  def window_handles(_), do: {:ok, ["main"]}

  @impl true
  def focus_window(_, _), do: {:ok, nil}

  @impl true
  def close_window(_), do: {:ok, nil}

  @impl true
  def maximize_window(_), do: {:ok, nil}

  @impl true
  def get_window_position(_), do: {:ok, %{"x" => 0, "y" => 0}}

  @impl true
  def set_window_position(_, _, _), do: {:ok, nil}

  @impl true
  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(_), do: {:ok, nil}

  def cleanup_stale_sessions, do: :ok

  # --- Internal ---

  defp remote_url do
    Application.get_env(:wallabidi, :lightpanda, []) |> Keyword.get(:remote_url)
  end

  defp lightpanda_available? do
    mod = Module.concat([Lightpanda])

    Code.ensure_loaded?(mod) and
      is_binary(apply(mod, :bin_path, [])) and
      File.exists?(apply(mod, :bin_path, []))
  rescue
    _ -> false
  end
end
