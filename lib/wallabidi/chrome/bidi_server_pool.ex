defmodule Wallabidi.Chrome.BidiServerPool do
  @moduledoc false

  # Supervises N chromium-bidi Node processes (`Wallabidi.Chrome.BidiServer`
  # instances) and round-robins session-creation requests across them.
  #
  # ## Why N processes
  #
  # chromium-bidi has internal serialization on operations like
  # `session.subscribe` that throttle high-concurrency runs (visible
  # as 60-second timeouts on perf_bench mc=8 BiDi runs). Splitting
  # sessions across N independent Node processes means each process
  # only ever sees ~mc/N concurrent sessions, well within
  # chromium-bidi's comfort zone.
  #
  # Each BidiServer is independent — they don't share state, don't
  # need IPC, and can start in parallel.
  #
  # ## Tuning N
  #
  # Trade-off: more processes = more parallelism but more memory
  # (Chrome subprocesses are heavy). Default heuristic:
  # `max(1, div(schedulers_online(), 4))`. Override with
  # `BIDI_SERVER_COUNT` env var or `:bidi_server_count` config.
  #
  # ## Round-robin
  #
  # `next_url/1` returns one of the N URLs, advancing an atomic
  # counter. Sessions are not load-balanced (no awareness of which
  # server is busy); under uniform test workloads round-robin is
  # close enough to optimal.

  use Supervisor

  @type ws_url :: String.t()

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

    child_names =
      for i <- 0..(count - 1) do
        {server_name(name, i), server_opts}
      end

    server_children =
      for {child_name, sopts} <- child_names do
        Supervisor.child_spec(
          {Wallabidi.Chrome.BidiServer, [name: child_name] ++ sopts},
          id: {Wallabidi.Chrome.BidiServer, child_name}
        )
      end

    children = [
      {Counter, [name: counter_name(name)]}
      | server_children
    ]

    # Stash the names list as part of the registry process so
    # next_url/1 can resolve them without scanning children.
    :persistent_term.put(
      {__MODULE__, name},
      Enum.map(child_names, fn {n, _} -> n end)
    )

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the WebSocket URL of the next BidiServer in round-robin
  order. Blocks until the chosen server is ready.
  """
  @spec next_url(atom) :: ws_url
  def next_url(pool_name) do
    names = :persistent_term.get({__MODULE__, pool_name})
    idx = rem(Counter.next(counter_name(pool_name)), length(names))
    server = Enum.at(names, idx)
    Wallabidi.Chrome.BidiServer.ws_url(server)
  end

  @doc """
  How many BidiServer instances this pool supervises.
  """
  @spec size(atom) :: non_neg_integer
  def size(pool_name) do
    case :persistent_term.get({__MODULE__, pool_name}, nil) do
      nil -> 0
      names -> length(names)
    end
  end

  defp resolve_count(nil) do
    case System.get_env("BIDI_SERVER_COUNT") do
      nil ->
        Application.get_env(
          :wallabidi,
          :bidi_server_count,
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
