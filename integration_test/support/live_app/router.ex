defmodule Wallabidi.Integration.LiveApp.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Wallabidi.Integration.LiveApp.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser
    live_session :default do
      live "/counter", Wallabidi.Integration.LiveApp.CounterLive
      live "/async", Wallabidi.Integration.LiveApp.AsyncLive
      live "/text-change", Wallabidi.Integration.LiveApp.TextChangeLive
    end
  end
end
