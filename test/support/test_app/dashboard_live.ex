defmodule Wallabidi.TestApp.DashboardLive do
  use Phoenix.LiveView
  import PhoenixTestOnly
  on_mount_if_test Wallabidi.Sandbox.Hook

  alias Wallabidi.TestApp.{Repo, User}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, socket |> assign(stats: nil) |> start_async(:load_stats, fn -> load_stats() end)}
    else
      {:ok, assign(socket, stats: nil)}
    end
  end

  defp load_stats do
    count = Repo.aggregate(User, :count)
    "Stats: #{count}"
  end

  def handle_async(:load_stats, {:ok, stats}, socket) do
    {:noreply, assign(socket, stats: stats)}
  end

  def handle_async(:load_stats, {:exit, reason}, socket) do
    require Logger
    Logger.error("start_async failed: #{inspect(reason)}")
    {:noreply, assign(socket, stats: "Error: #{inspect(reason)}")}
  end

  def render(assigns) do
    ~H"""
    <h1>Dashboard</h1>
    <div id="stats">{@stats || "Loading..."}</div>
    """
  end
end
