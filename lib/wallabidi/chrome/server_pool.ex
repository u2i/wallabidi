defmodule Wallabidi.Chrome.ServerPool do
  @moduledoc false

  # Supervises N Chrome browser processes (`Wallabidi.Chrome.Server`
  # instances) and round-robins session-creation requests across
  # them.
  #
  # ## Why N processes
  #
  # Even with the wallabidi-side session pool relieving shared-WS
  # mailbox contention on a single Chrome, all sessions still share
  # one Chrome process's V8/renderer/network threads. At high test
  # concurrency that single Chrome becomes the bottleneck.
  #
  # Splitting sessions across N independent Chrome processes lets
  # each one only see ~mc/N concurrent BrowserContexts, well within
  # Chrome's comfort zone for any non-stress test workload.
  #
  # Same architectural shape as `Wallabidi.Chrome.BidiServerPool` for
  # chromium-bidi.
  #
  # ## Tuning N
  #
  # Default heuristic: `max(1, div(schedulers_online(), 4))`.
  # Override via `CHROME_SERVER_COUNT` env var or
  # `:wallabidi, :chrome_server_count` config.
  #
  # Trade-off: each Chrome process holds ~200-500MB resident memory
  # at idle (more once Pages exist). count=1 stays out of the way
  # for users not fighting concurrency bottlenecks.
  #
  # ## Round-robin
  #
  # Each call to `next_server/1` returns the next server name in
  # rotation. The caller passes that to
  # `Wallabidi.Chrome.SharedConnection.get_for/2` to obtain that
  # server's V2.WebSocket pid. SharedConnection lazy-connects each
  # WS and keeps one cached entry per server name.

  use Supervisor

  defmodule Counter do
    @moduledoc false
    use Agent

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.start_link(fn -> 0 end, name: name)
    end

    def next(agent) do
      Agent.get_and_update(agent, fn n -> {n, n + 1} end)
    end
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    count = resolve_count(Keyword.get(opts, :count))
    server_opts = Keyword.get(opts, :server_opts, [])

    server_names =
      for i <- 0..(count - 1) do
        server_name(name, i)
      end

    server_children =
      for child_name <- server_names do
        Supervisor.child_spec(
          {Wallabidi.Chrome.Server, [name: child_name] ++ server_opts},
          id: {Wallabidi.Chrome.Server, child_name}
        )
      end

    children = [
      {Counter, [name: counter_name(name)]}
      | server_children
    ]

    :persistent_term.put({__MODULE__, name}, server_names)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the next server's name in round-robin order. Pass it to
  `Wallabidi.Chrome.SharedConnection.get_for/2` to acquire the
  underlying V2.WebSocket pid.
  """
  @spec next_server(atom) :: atom
  def next_server(pool_name) do
    names = :persistent_term.get({__MODULE__, pool_name})
    idx = rem(Counter.next(counter_name(pool_name)), length(names))
    Enum.at(names, idx)
  end

  @doc """
  All server names this pool supervises.
  """
  @spec server_names(atom) :: [atom]
  def server_names(pool_name) do
    :persistent_term.get({__MODULE__, pool_name}, [])
  end

  defp resolve_count(nil) do
    case System.get_env("CHROME_SERVER_COUNT") do
      nil ->
        Application.get_env(
          :wallabidi,
          :chrome_server_count,
          max(1, div(System.schedulers_online(), 4))
        )

      str ->
        String.to_integer(str)
    end
  end

  defp resolve_count(n) when is_integer(n) and n >= 1, do: n

  defp counter_name(pool_name), do: Module.concat(pool_name, Counter)
  defp server_name(pool_name, idx), do: Module.concat(pool_name, "Server#{idx}")
end
