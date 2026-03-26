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
      live "/nav-source", Wallabidi.Integration.LiveApp.NavSourceLive
      live "/nav-dest", Wallabidi.Integration.LiveApp.NavDestLive
      live "/multi", Wallabidi.Integration.LiveApp.MultiElementLive
      live "/form-redirect", Wallabidi.Integration.LiveApp.FormRedirectLive
      live "/js-toggle", Wallabidi.Integration.LiveApp.JsToggleLive
      live "/form", Wallabidi.Integration.LiveApp.FormLive
    end

    # Separate live_session — navigating here from :default triggers a full page load
    live_session :other do
      live "/full-nav-dest", Wallabidi.Integration.LiveApp.FullNavDestLive
    end

    get "/plain-form", Wallabidi.Integration.LiveApp.PlainFormController, :show
    post "/plain-form", Wallabidi.Integration.LiveApp.PlainFormController, :submit
  end
end
