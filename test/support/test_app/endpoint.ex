defmodule Wallabidi.TestApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallabidi
  import Wallabidi.Sandbox

  wallabidi_plug()

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [:user_agent]])

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"}
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"}
  )

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
