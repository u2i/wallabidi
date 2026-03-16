defmodule Wallabidi.TestApp.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {Wallabidi.TestApp.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    live_session :default, on_mount: [Wallabidi.LiveSandbox] do
      live("/users", Wallabidi.TestApp.UsersLive)
      live("/dashboard", Wallabidi.TestApp.DashboardLive)
      live("/cached", Wallabidi.TestApp.CachedLive)
      live("/greeting", Wallabidi.TestApp.GreetingLive)
    end
  end
end
