defmodule Wallabidi.TestApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallabidi

  plug(Wallabidi.Sandbox)

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [:user_agent]])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session,
    store: :cookie,
    key: "_test_key",
    signing_salt: "test_salt"
  )

  plug(Wallabidi.TestApp.Router)
end
