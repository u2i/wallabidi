if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) do
  defmodule Wallabidi.SandboxHelper do
    @moduledoc """
    Helpers for propagating sandbox access to processes spawned outside
    the normal Task/$callers chain (e.g. Cachex workers, GenServer calls).

    ## Usage

    Wrap any function that will be executed in a spawned worker:

        Cachex.fetch(:my_cache, key, fn key ->
          Wallabidi.SandboxHelper.ensure_sandbox_access()
          MyApp.Repo.get(User, key)
        end)

    Or use the `sandbox_wrap/1` helper:

        Cachex.fetch(:my_cache, key,
          Wallabidi.SandboxHelper.sandbox_wrap(fn key ->
            MyApp.Repo.get(User, key)
          end)
        )

    These are no-ops in production (when no sandbox metadata is stored).
    """

    @doc """
    Ensures the current process has sandbox access. Call this at the start
    of any function that runs in a `spawn_link`'d worker and needs DB access.

    No-op when not in a test context.
    """
    def ensure_sandbox_access do
      metadata =
        Process.get(:wallabidi_sandbox_metadata) ||
          inherit_metadata_from_caller()

      if metadata do
        Phoenix.Ecto.SQL.Sandbox.allow(metadata, Wallabidi.Sandbox.sandbox_module())
        Process.put(:wallabidi_sandbox_metadata, metadata)
      end

      :ok
    end

    defp inherit_metadata_from_caller do
      with [parent | _] <- Process.get(:"$callers") || [],
           {:dictionary, dict} <- :erlang.process_info(parent, :dictionary),
           {_, metadata} when not is_nil(metadata) <-
             List.keyfind(dict, :wallabidi_sandbox_metadata, 0) do
        metadata
      else
        _ -> nil
      end
    end

    @doc """
    Wraps a function so that sandbox access is ensured before it executes.
    Use this to wrap callbacks passed to libraries like Cachex:

        Cachex.fetch(:cache, key, Wallabidi.SandboxHelper.sandbox_wrap(fn key ->
          MyApp.Repo.get(User, key)
        end))
    """
    def sandbox_wrap(fun) when is_function(fun, 1) do
      # Capture the metadata from the current process
      metadata = Process.get(:wallabidi_sandbox_metadata)

      fn arg ->
        if metadata do
          Process.put(:wallabidi_sandbox_metadata, metadata)

          Phoenix.Ecto.SQL.Sandbox.allow(
            metadata,
            Wallabidi.Sandbox.sandbox_module()
          )
        end

        fun.(arg)
      end
    end

    def sandbox_wrap(fun) when is_function(fun, 0) do
      metadata = Process.get(:wallabidi_sandbox_metadata)

      fn ->
        if metadata do
          Process.put(:wallabidi_sandbox_metadata, metadata)

          Phoenix.Ecto.SQL.Sandbox.allow(
            metadata,
            Wallabidi.Sandbox.sandbox_module()
          )
        end

        fun.()
      end
    end
  end
end
