defmodule Wallabidi.Feature do
  @moduledoc """
  Helpers for writing features.

  You can `use` or `import` this module.

  ## use Wallabidi.Feature

  Calling this module with `use` will automatically call `use Wallabidi.DSL`.

  When called with `use` and you are using Ecto, please configure your `otp_app`.

  ```
  config :wallabidi, otp_app: :your_app
  ```
  """

  defmacro __using__(_) do
    quote do
      ExUnit.Case.register_attribute(__MODULE__, :sessions)

      use Wallabidi.DSL
      import Wallabidi.Feature

      setup context do
        if context[:test_type] == :feature do
          metadata = unquote(__MODULE__).Utils.maybe_checkout_repos(context[:async])
          caches = unquote(__MODULE__).Utils.maybe_checkout_caches()
          flags = unquote(__MODULE__).Utils.maybe_checkout_flags()

          start_session_opts = [metadata: metadata]

          result =
            get_in(context, [:registered, :sessions])
            |> unquote(__MODULE__).Utils.sessions_iterable()
            |> Enum.map(fn
              opts when is_list(opts) ->
                unquote(__MODULE__).Utils.start_session(opts, start_session_opts)

              i when is_number(i) ->
                unquote(__MODULE__).Utils.start_session([], start_session_opts)
            end)
            |> unquote(__MODULE__).Utils.build_setup_return()

          test_pid = self()

          on_exit(fn ->
            # End browser sessions first — closes Chrome tabs, disconnects
            # LiveView channels, stops any in-flight requests
            unquote(__MODULE__).Utils.end_all_sessions(test_pid)

            unquote(__MODULE__).Utils.maybe_checkin_flags(flags)
            unquote(__MODULE__).Utils.maybe_checkin_caches(caches)
          end)

          result
        else
          :ok
        end
      end
    end
  end

  @doc """
  Defines a feature with a message.

  Adding `import Wallabidi.Feature` to your test module will import the `Wallabidi.Feature.feature/3` macro. This is a drop in replacement for the `ExUnit.Case.test/3` macro that you normally use.

  Adding `use Wallabidi.Feature` to your test module will act the same as `import Wallabidi.Feature`, as well as configure your Ecto repos properly and pass a `Wallabidi.Session` into the test context.

  ## Sessions

  When called with `use`, the `Wallabidi.Feature.feature/3` macro will automatically start a single session using the currently configured capabilities and is passed to the feature via the `:session` key in the context.

  ```
  feature "test with a single session", %{session: session} do
    # ...
  end
  ```

  If you would like to start multiple sessions, assign the `@sessions` attribute to the number of sessions that the feature should start, and they will be pass to the feature via the `:sessions` key in the context.

  ```
  @sessions 2
  feature "test with a two sessions", %{sessions: [session_1, sessions_2]} do
    # ...
  end
  ```

  If you need to change the headless mode, binary path, or capabilities sent to the session for a specific feature, you can assign `@sessions` to a list of keyword lists of the options to be passed to `Wallabidi.start_session/1`. This will start the number of sessions equal to the size of the list.

  ```
  @sessions [
    [headless: false, binary: "some_path", capabilities: %{}]
  ]
  feature "test with different capabilities", %{session: session} do
    # ...
  end
  ```

  If you don't wish to `use Wallabidi.Feature` in your test module, you can add the following code to configure Ecto and create a session.

  ```
  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(YourApp.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(YourApp.Repo, {:shared, self()})
    end

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(YourApp.Repo, self())
    {:ok, session} = Wallabidi.start_session(metadata: metadata)

    {:ok, session: session}
  end
  ```

  ## Screenshots

  If you have configured `screenshot_on_failure` to be true, any exceptions raised during the feature will trigger a screenshot to be taken.
  """

  defmacro feature(message, context \\ quote(do: _), contents) do
    contents =
      quote do
        try do
          unquote(contents)
          :ok
        rescue
          e ->
            if Wallabidi.screenshot_on_failure?() do
              unquote(__MODULE__).Utils.take_screenshots_for_sessions(self(), unquote(message))
            end

            reraise(e, __STACKTRACE__)
        end
      end

    context = Macro.escape(context)
    contents = Macro.escape(contents, unquote: true)

    %{module: mod, file: file, line: line} = __CALLER__

    quote bind_quoted: [
            mod: mod,
            file: file,
            line: line,
            context: context,
            contents: contents,
            message: message
          ] do
      name = ExUnit.Case.register_test(mod, file, line, :feature, message, [:feature])

      def unquote(name)(unquote(context)), do: unquote(contents)
    end
  end

  defmodule Utils do
    @includes_ecto Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) &&
                     Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox)
    @moduledoc false

    def build_setup_return([session]) do
      [session: session]
    end

    def build_setup_return(sessions) do
      [sessions: sessions]
    end

    def sessions_iterable(nil), do: 1..1
    def sessions_iterable(count) when is_number(count), do: 1..count
    def sessions_iterable(capabilities) when is_list(capabilities), do: capabilities

    def start_session(more_opts, start_session_opts) when is_list(more_opts) do
      {:ok, session} =
        start_session_opts
        |> Keyword.merge(more_opts)
        |> Wallabidi.start_session()

      session
    end

    if @includes_ecto do
      def maybe_checkout_repos(async?) do
        otp_app()
        |> ecto_repos()
        |> Enum.map(&checkout_ecto_repos(&1, async?))
        |> metadata_for_ecto_repos()
      end

      defp otp_app(), do: Application.get_env(:wallabidi, :otp_app)

      defp ecto_repos(nil), do: []
      defp ecto_repos(otp_app), do: Application.get_env(otp_app, :ecto_repos, [])

      defp checkout_ecto_repos(repo, async) do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)

        unless async, do: Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

        repo
      end

      defp metadata_for_ecto_repos([]), do: Map.new()

      defp metadata_for_ecto_repos(repos) do
        Phoenix.Ecto.SQL.Sandbox.metadata_for(repos, self())
      end
    else
      def maybe_checkout_repos(_) do
        ""
      end
    end

    def maybe_checkout_caches do
      mod = cachex_sandbox_mod()

      if mod && Process.whereis(mod) do
        mod.checkout()
      else
        nil
      end
    end

    def maybe_checkin_caches(nil), do: :ok

    def maybe_checkin_caches(caches) do
      mod = cachex_sandbox_mod()
      if mod && Process.whereis(mod), do: mod.checkin(caches)
    end

    defp cachex_sandbox_mod do
      mod = Module.concat([Cachex, Sandbox])
      if Code.ensure_loaded?(mod), do: mod
    end

    def maybe_checkout_flags do
      mod = fwf_sandbox_mod()

      if mod && Process.whereis(mod) do
        mod.checkout()
      else
        nil
      end
    end

    def maybe_checkin_flags(nil), do: :ok

    def maybe_checkin_flags(flags) do
      mod = fwf_sandbox_mod()
      if mod && Process.whereis(mod), do: mod.checkin(flags)
    end

    defp fwf_sandbox_mod do
      mod = Module.concat([FunWithFlags, Sandbox])
      if Code.ensure_loaded?(mod), do: mod
    end

    def end_all_sessions(owner_pid) do
      sessions = Wallabidi.SessionStore.list_sessions_for(owner_pid: owner_pid)

      if sessions != [] do
        # Find processes with our test pid in $callers BEFORE closing sessions
        child_pids = find_callers_of(owner_pid)

        # Monitor them so we can wait for termination
        refs =
          for pid <- child_pids do
            Process.monitor(pid)
          end

        # Close all browser sessions — triggers WebSocket close → channel termination
        for session <- sessions do
          try do
            Wallabidi.end_session(session)
          rescue
            _ -> :ok
          end
        end

        # Wait for LiveView channel processes to terminate (up to 5s)
        for ref <- refs do
          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          after
            5_000 -> Process.demonitor(ref, [:flush])
          end
        end
      end
    end

    defp find_callers_of(owner_pid) do
      Process.list()
      |> Enum.filter(fn pid ->
        pid != owner_pid and pid != self() and has_caller?(pid, owner_pid)
      end)
    end

    defp has_caller?(pid, owner) do
      case :erlang.process_info(pid, :dictionary) do
        {:dictionary, dict} ->
          case List.keyfind(dict, :"$callers", 0) do
            {:"$callers", callers} -> owner in callers
            _ -> false
          end

        _ ->
          false
      end
    catch
      _, _ -> false
    end

    def take_screenshots_for_sessions(pid, test_name) do
      time = :erlang.system_time(:second) |> to_string()
      test_name = String.replace(test_name, " ", "_")

      screenshot_paths =
        Wallabidi.SessionStore.list_sessions_for(owner_pid: pid)
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {s, i} ->
          filename = time <> "_" <> test_name <> "(#{i})"

          Wallabidi.Browser.take_screenshot(s, name: filename).screenshots
        end)
        |> Enum.map_join("\n- ", &Wallabidi.Browser.build_file_url/1)

      IO.write("\n- #{screenshot_paths}")
    end
  end
end
