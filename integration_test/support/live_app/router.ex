defmodule Wallabidi.Integration.LiveApp.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Wallabidi.Integration.LiveApp.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    live_session :default do
      live("/counter", Wallabidi.Integration.LiveApp.CounterLive)
      live("/async", Wallabidi.Integration.LiveApp.AsyncLive)
      live("/text-change", Wallabidi.Integration.LiveApp.TextChangeLive)
      live("/nav-source", Wallabidi.Integration.LiveApp.NavSourceLive)
      live("/nav-dest", Wallabidi.Integration.LiveApp.NavDestLive)
      live("/multi", Wallabidi.Integration.LiveApp.MultiElementLive)
      live("/form-redirect", Wallabidi.Integration.LiveApp.FormRedirectLive)
      live("/js-toggle", Wallabidi.Integration.LiveApp.JsToggleLive)
      live("/form", Wallabidi.Integration.LiveApp.FormLive)
      live("/trigger-action", Wallabidi.Integration.LiveApp.TriggerActionLive)
      live("/pubsub", Wallabidi.Integration.LiveApp.PubSubLive)
      live("/slow-nav-dest", Wallabidi.Integration.LiveApp.SlowNavDestLive)
      live("/slow-event", Wallabidi.Integration.LiveApp.SlowEventLive)
      live("/slow-event-dest", Wallabidi.Integration.LiveApp.SlowEventDestLive)
      live("/slow-evt-slow-dest", Wallabidi.Integration.LiveApp.SlowEventToSlowMountLive)
      live("/slow-evt-slow-dest-target", Wallabidi.Integration.LiveApp.SlowMountDestLive)
      live("/optimistic-counter", Wallabidi.Integration.LiveApp.OptimisticCounterLive)
    end

    # Separate live_session — navigating here from :default triggers a full page load
    live_session :other do
      live("/full-nav-dest", Wallabidi.Integration.LiveApp.FullNavDestLive)
    end

    get("/plain-form", Wallabidi.Integration.LiveApp.PlainFormController, :show)
    post("/plain-form", Wallabidi.Integration.LiveApp.PlainFormController, :submit)

    post(
      "/trigger-action-target",
      Wallabidi.Integration.LiveApp.PlainFormController,
      :trigger_action_target
    )

    get("/join-pending", Wallabidi.Integration.LiveApp.PlainFormController, :join_pending)
  end
end
