defmodule Wallabidi.TestApp.Repo do
  use Ecto.Repo,
    otp_app: :wallabidi,
    adapter: Ecto.Adapters.SQLite3
end
