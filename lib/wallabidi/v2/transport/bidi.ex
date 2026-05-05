defmodule Wallabidi.V2.Transport.BiDi do
  @moduledoc false

  # V2 transport for chromium-bidi: one POST → one WS → one Chrome.
  #
  # The chromium-bidi server (priv/bidi-server/run.mjs) exposes a
  # WebDriver-style HTTP `POST /session` that pre-binds a fresh
  # browser session to the WebSocket upgrade. Each test session does
  # its own POST, opens the returned WS, and runs BiDi commands
  # directly — no userContext multiplexing, no shared connection.
  #
  # ## Phase A scope
  #
  # Brings up the session via:
  #   1. POST /session → webSocketUrl
  #   2. open WS via SessionActor (which wraps BiDi.WebSocketClient)
  #   3. browsingContext.create → context id
  #
  # Phase B will install lifecycle subscriptions; phase C the
  # bootstrap preload script + script.message routing.

  alias Wallabidi.Session
  alias Wallabidi.V2.Transport.BiDi.{Handshake, SessionActor}
  alias Wallabidi.V2.Transport.Protocol

  @doc """
  Bring up a new BiDi session.

  Required opts:
    * `:base_url`       — the chromium-bidi server's HTTP base
                          URL (e.g. `http://localhost:12345`)
    * `:session_struct` — `%Wallabidi.Session{}` template; this
                          function fills in `pid`, `bidi_pid` and
                          `browsing_context`.

  Optional:
    * `:owner`        — process to monitor (defaults to caller)
    * `:teardown_fun` — 1-arity, called from terminate/2
    * `:capabilities` — capabilities map for the POST body
  """
  @spec start_session(keyword) :: {:ok, Session.t()} | {:error, term}
  def start_session(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    session_struct = Keyword.fetch!(opts, :session_struct)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    handshake_opts =
      case Keyword.fetch(opts, :capabilities) do
        {:ok, caps} -> [capabilities: caps]
        :error -> []
      end

    with {:ok, ws_url} <- Handshake.post_session(base_url, handshake_opts),
         {:ok, session} <-
           SessionActor.start_link(
             ws_url: ws_url,
             init_fun: fn -> {:ok, session_struct} end,
             teardown_fun: teardown_fun,
             owner: owner
           ),
         {:ok, context_id} <- find_or_create_initial_context(session),
         :ok <- install_bootstrap(session) do
      session = %{session | browsing_context: context_id}

      # Mirror the actor's session-struct view so subsequent reads
      # via :get_session also see the populated browsing_context.
      :ok = GenServer.call(session.pid, {:update_browsing_context, nil, context_id})

      {:ok, session}
    end
  end

  # Chrome launches with a default about:blank tab. Reuse it instead
  # of creating a sibling — otherwise window_handles sees TWO tabs at
  # session start (the leftover plus our newly-created one), which
  # confuses tests that check tab counts.
  defp find_or_create_initial_context(session) do
    case Protocol.cdp_send(session, "browsingContext.getTree", %{}, []) do
      {:ok, %{"contexts" => [%{"context" => existing} | _]}} when is_binary(existing) ->
        {:ok, existing}

      _ ->
        case Protocol.cdp_send(session, "browsingContext.create", %{"type" => "tab"}, []) do
          {:ok, %{"context" => context_id}} -> {:ok, context_id}
          err -> err
        end
    end
  end

  # Install the shared Wallabidi.Bootstrap as a BiDi preload script.
  # The script receives `__wallabidi` as a channel callback parameter;
  # any payload it sends comes back as a `script.message` event that
  # the SessionActor decodes into find / page_ready dispatches.
  defp install_bootstrap(session) do
    fn_decl = Wallabidi.Bootstrap.bidi_preload()
    channel_arg = [%{"type" => "channel", "value" => %{"channel" => "__wallabidi"}}]

    case Protocol.cdp_send(
           session,
           "script.addPreloadScript",
           %{"functionDeclaration" => fn_decl, "arguments" => channel_arg},
           []
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end
end
