defmodule Wallabidi.Integration.LiveApp.Repo do
  use Ecto.Repo,
    otp_app: :wallabidi,
    adapter: Ecto.Adapters.Postgres
end