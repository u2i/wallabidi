defmodule Wallabidi.TestApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallabidi

  @session_options [
    store: :cookie,
    key: "_test_key",
    signing_salt: "test_salt"
  ]

  import SandboxShim
  sandbox_plugs()

  sandbox_socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"}
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"}
  )

  # Suppress favicon 404 noise in test logs
  plug(:favicon)

  defp favicon(%{path_info: ["favicon.ico"]} = conn, _opts) do
    conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()
  end

  defp favicon(conn, _opts), do: conn

  # Serve integration test static pages (forms.html, page_1.html, etc.)
  # so the LiveView driver can access them via dispatch without HTTP
  plug(Plug.Static, at: "/", from: "integration_test/support/pages")

  # Serve index.html for / (Plug.Static doesn't do directory indexes)
  plug(:maybe_index_html)

  defp maybe_index_html(%{path_info: [], method: "GET"} = conn, _opts) do
    path = Path.join("integration_test/support/pages", "index.html")

    if File.exists?(path) do
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, File.read!(path))
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  defp maybe_index_html(conn, _opts), do: conn

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(Wallabidi.TestApp.Router)
end
