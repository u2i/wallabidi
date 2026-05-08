defmodule Wallabidi.Transport.BiDi.Handshake do
  @moduledoc false

  # WebDriver-BiDi HTTP `POST /session` step.
  #
  # chromium-bidi's WebSocketServer creates a fresh session record per
  # POST and replies with a `webSocketUrl` that the caller must then
  # WebSocket-upgrade to. The Mapper spawns a Chrome+BrowserInstance
  # only when that WS connection is accepted.
  #
  # See: https://w3c.github.io/webdriver-bidi/#transport
  #      priv/bidi-server/node_modules/chromium-bidi/lib/esm/bidiServer/WebSocketServer.js

  # Chrome runs headless by default — matches the legacy Chrome (BiDi)
  # driver and lets `mix test.chrome.bidi_v2` finish suites without
  # piling visible windows on the user's desktop. Override via
  # `:capabilities` opt to opt in to a visible browser.
  #
  # `unhandledPromptBehavior: "ignore"` keeps user prompts (alert /
  # confirm / prompt) on screen until the test explicitly handles
  # them via browsingContext.handleUserPrompt — without this Chrome's
  # default policy auto-dismisses unhandled prompts before the
  # `userPromptOpened` event handler can react.
  @default_capabilities %{
    "alwaysMatch" => %{
      "browserName" => "chrome",
      "webSocketUrl" => true,
      "unhandledPromptBehavior" => "ignore",
      "goog:chromeOptions" => %{
        "args" => ["--headless=new"]
      }
    }
  }

  @doc """
  POST `/session` to a chromium-bidi server's HTTP endpoint and return
  the per-session WebSocket URL.

  `base_url` is the form `http://host:port` — use the *http* scheme even
  though the chromium-bidi server upgrades the same port. The WS URL we
  receive back from the server already carries the right scheme.
  """
  @spec post_session(String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def post_session(base_url, opts \\ []) when is_binary(base_url) do
    capabilities = Keyword.get(opts, :capabilities, @default_capabilities)
    timeout = Keyword.get(opts, :timeout, 10_000)

    body = Jason.encode!(%{"capabilities" => capabilities})
    uri = URI.parse(base_url)
    scheme = if uri.scheme in ["https", "wss"], do: :https, else: :http
    host = uri.host || "localhost"
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", "/session", headers, body),
         {:ok, status, resp_body} <- recv_response(conn, ref, timeout),
         :ok <- check_status(status),
         {:ok, ws_url} <- decode_ws_url(resp_body) do
      {:ok, ws_url}
    else
      {:error, %Mint.TransportError{} = err} -> {:error, {:http_error, err}}
      {:error, _conn, reason} -> {:error, {:http_error, reason}}
      {:error, _} = err -> err
    end
  end

  defp recv_response(conn, ref, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_recv_response(conn, ref, %{status: nil, body: ""}, deadline)
  end

  defp do_recv_response(conn, ref, acc, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case fold_responses(responses, ref, acc) do
              {:done, status, body} ->
                Mint.HTTP.close(conn)
                {:ok, status, body}

              {:cont, acc} ->
                do_recv_response(conn, ref, acc, deadline)

              {:error, reason} ->
                Mint.HTTP.close(conn)
                {:error, reason}
            end

          {:error, _conn, reason, _resp} ->
            {:error, reason}

          :unknown ->
            do_recv_response(conn, ref, acc, deadline)
        end
    after
      remaining -> {:error, :timeout}
    end
  end

  defp fold_responses([], _ref, acc), do: {:cont, acc}

  defp fold_responses([{:status, ref, status} | rest], ref, acc),
    do: fold_responses(rest, ref, %{acc | status: status})

  defp fold_responses([{:headers, ref, _} | rest], ref, acc),
    do: fold_responses(rest, ref, acc)

  defp fold_responses([{:data, ref, chunk} | rest], ref, acc),
    do: fold_responses(rest, ref, %{acc | body: acc.body <> chunk})

  defp fold_responses([{:done, ref} | _], ref, acc),
    do: {:done, acc.status, acc.body}

  defp fold_responses([{:error, ref, reason} | _], ref, _acc),
    do: {:error, reason}

  defp fold_responses([_ | rest], ref, acc), do: fold_responses(rest, ref, acc)

  defp check_status(200), do: :ok
  defp check_status(status), do: {:error, {:bad_status, status}}

  defp decode_ws_url(body) do
    case Jason.decode(body) do
      {:ok, %{"value" => %{"capabilities" => %{"webSocketUrl" => url}}}}
      when is_binary(url) ->
        {:ok, url}

      {:ok, other} ->
        {:error, {:no_ws_url, other}}

      {:error, reason} ->
        {:error, {:bad_json, reason}}
    end
  end
end
