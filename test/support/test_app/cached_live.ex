defmodule Wallabidi.TestApp.CachedLive do
  use Phoenix.LiveView
  import Wallabidi.Sandbox
  wallabidi_on_mount()

  alias Wallabidi.TestApp.{Repo, User}

  def mount(_params, _session, socket) do
    # Use Cachex.fetch which spawns a Courier worker via spawn_link.
    # With Cachex 4.1+, the worker has $callers set, so it can access
    # the Ecto sandbox.
    users =
      case Cachex.fetch(:test_app_cache, "users", fn _key ->
             {:commit, Repo.all(User)}
           end) do
        {:ok, users} -> users
        {:commit, users} -> users
      end

    {:ok, assign(socket, users: users)}
  end

  def render(assigns) do
    ~H"""
    <h1>Cached Users</h1>
    <ul>
      <li :for={user <- @users}>{user.name}</li>
    </ul>
    """
  end
end
