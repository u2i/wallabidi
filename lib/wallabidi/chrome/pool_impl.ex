defmodule Wallabidi.Chrome.PoolImpl do
  @moduledoc false

  # Pool implementation for the Chrome (BiDi) driver.
  #
  # ## Slot model
  #
  # A slot is one WebSocket connection to chromium-bidi. chromium-bidi
  # spawns a Chrome + BiDi Mapper per WebSocket, so N slots = N Chromes.
  # The Mapper inside each Chrome is single-threaded (one JS event
  # loop), so all sessions on one slot serialize. Pool size therefore
  # caps real concurrency.
  #
  # ## Session model
  #
  # Per-test isolation uses BiDi userContexts. Each session creates a
  # fresh userContext + browsingContext inside its slot's Chrome,
  # tears them down on checkin. The slot's connection stays warm
  # across sessions — no Chrome restart between tests.
  #
  # The bootstrap (window.__w + addPreloadScript) is installed once
  # per slot at open_slot/1, not per session, so per-test cost is
  # just the userContext + browsingContext create.

  @behaviour Wallabidi.Driver.Pool

  alias Wallabidi.BiDi.{Commands, WebSocketClient}
  alias Wallabidi.Driver.SessionLifecycle

  @global_event_methods [
    "log.entryAdded",
    "browsingContext.userPromptOpened",
    "browsingContext.load",
    "browsingContext.domContentLoaded",
    "script.message",
    "network.beforeRequestSent"
  ]

  @impl true
  def open_slot(_opts) do
    ws_url = Wallabidi.Chrome.BidiServer.ws_url(Wallabidi.Chrome.BidiServer)

    with {:ok, bidi_pid} <- WebSocketClient.start_link(ws_url),
         :ok <- session_new(bidi_pid),
         :ok <- subscribe_globally(bidi_pid),
         :ok <- install_bootstrap_preload(bidi_pid) do
      {:ok, %{bidi_pid: bidi_pid}}
    else
      error ->
        {:error, error}
    end
  end

  @impl true
  def close_slot(%{bidi_pid: bidi_pid}) do
    SessionLifecycle.safe(bidi_pid, &WebSocketClient.close/1)
    :ok
  end

  @impl true
  def prepare_session(%{bidi_pid: bidi_pid}, opts) do
    with {:ok, user_context_id} <- create_user_context(bidi_pid),
         {:ok, browsing_context_id} <- create_browsing_context(bidi_pid, user_context_id),
         :ok <- maybe_apply_window_size(bidi_pid, browsing_context_id, opts) do
      session_state = %{
        user_context_id: user_context_id,
        browsing_context_id: browsing_context_id
      }

      {:ok, session_state}
    end
  end

  @impl true
  def finalize_session(%{bidi_pid: bidi_pid}, %{user_context_id: uc}) when is_binary(uc) do
    {method, params} = Commands.remove_user_context(uc)

    SessionLifecycle.safe(fn ->
      WebSocketClient.send_command(bidi_pid, method, params, 5_000)
    end)

    :ok
  end

  def finalize_session(_, _), do: :ok

  @impl true
  def reset_slot(%{bidi_pid: bidi_pid}) do
    if Process.alive?(bidi_pid), do: :ok, else: :must_recreate
  end

  # --- Internal ---

  defp session_new(bidi_pid) do
    case WebSocketClient.send_command(bidi_pid, "session.new", %{
           capabilities: %{
             alwaysMatch: %{
               unhandledPromptBehavior: "ignore",
               "goog:chromeOptions": %{args: chrome_args()}
             }
           }
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp chrome_args do
    [
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--disable-extensions",
      "--disable-sync",
      "--disable-translate",
      "--metrics-recording-only",
      "--use-mock-keychain",
      "--window-size=1280,800"
    ]
  end

  defp subscribe_globally(bidi_pid) do
    {method, params} = Commands.subscribe(@global_event_methods)

    case WebSocketClient.send_command(bidi_pid, method, params, 10_000) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  defp install_bootstrap_preload(bidi_pid) do
    channel_arg = [%{type: "channel", value: %{channel: "__wallabidi"}}]
    bootstrap_fn = Wallabidi.Bootstrap.bidi_preload()

    {cmd, params} = Commands.add_preload_script(bootstrap_fn, channel_arg)

    case WebSocketClient.send_command(bidi_pid, cmd, params) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp create_user_context(bidi_pid) do
    {method, params} = Commands.create_user_context()

    case WebSocketClient.send_command(bidi_pid, method, params) do
      {:ok, %{"result" => %{"userContext" => uc}}} -> {:ok, uc}
      {:ok, %{"userContext" => uc}} -> {:ok, uc}
      other -> {:error, {:create_user_context_failed, other}}
    end
  end

  defp create_browsing_context(bidi_pid, user_context_id) do
    {method, params} =
      Commands.create_context("tab", %{userContext: user_context_id})

    case WebSocketClient.send_command(bidi_pid, method, params) do
      {:ok, %{"result" => %{"context" => ctx}}} -> {:ok, ctx}
      {:ok, %{"context" => ctx}} -> {:ok, ctx}
      other -> {:error, {:create_context_failed, other}}
    end
  end

  defp maybe_apply_window_size(_bidi_pid, _ctx, opts) do
    case Keyword.get(opts, :window_size) do
      nil ->
        :ok

      _size ->
        # Window size is applied at session level by the caller; we
        # could also do it here via browsingContext.setViewport, but
        # leaving that to the higher-level start_session for now.
        :ok
    end
  end
end
