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

  # Serve integration test static pages (forms.html, page_1.html, etc.)
  # so the LiveView driver can access them via dispatch without HTTP
  plug(Plug.Static, at: "/", from: "integration_test/support/pages")

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(Wallabidi.TestApp.Router)
end
