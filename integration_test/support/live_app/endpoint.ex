defmodule Wallabidi.Integration.LiveApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallabidi
  import SandboxShim

  @session_options [
    store: :cookie,
    key: "_live_test",
    signing_salt: "integration_test_salt"
  ]

  # === Sandbox integration (from TestApp) ===
  sandbox_plugs()
  sandbox_socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]
  )

  # === Phoenix assets (from TestApp) ===
  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"})

  # === Static pages (from Integration) ===
  plug(Plug.Static, at: "/", from: "integration_test/support/pages")
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

  # Suppress favicon 404 noise
  plug(:favicon)

  defp favicon(%{path_info: ["favicon.ico"]} = conn, _opts) do
    conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()
  end

  defp favicon(conn, _opts), do: conn

  # === Parsers (from TestApp) ===
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(Wallabidi.Integration.LiveApp.Router)
end