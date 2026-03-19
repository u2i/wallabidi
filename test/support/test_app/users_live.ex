defmodule Wallabidi.TestApp.UsersLive do
  use Phoenix.LiveView
  import PhoenixTestOnly
  on_mount_if_test Wallabidi.Sandbox.Hook

  alias Wallabidi.TestApp.{Repo, User}

  def mount(_params, _session, socket) do
    users = Repo.all(User)
    {:ok, assign(socket, users: users)}
  end

  def render(assigns) do
    ~H"""
    <h1>Users</h1>
    <ul>
      <li :for={user <- @users}>{user.name}</li>
    </ul>
    """
  end
end
