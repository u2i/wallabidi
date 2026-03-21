defmodule Wallabidi.Integration.LiveApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallabidi

  @session_options [
    store: :cookie,
    key: "_live_test",
    signing_salt: "integration_test_salt"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent, session: @session_options]]

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["*/*"]

  plug Plug.Session, @session_options
  plug Wallabidi.Integration.LiveApp.Router
end
