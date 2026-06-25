defmodule Wallabidi.Integration.LiveApp.UsersLive do
  use Phoenix.LiveView
  import SandboxShim
  
  sandbox_on_mount()

  alias Wallabidi.Integration.LiveApp.{Repo, User}

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