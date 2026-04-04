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
          {metadata, sandbox} = unquote(__MODULE__).Utils.checkout_sandbox(context[:async])

          driver = unquote(__MODULE__).Utils.resolve_test_driver(context)

          start_session_opts = [driver: driver, metadata: metadata]

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

          # Register session close as a cleanup callback — runs before
          # sandbox rollback, OwnershipErrors from dying LiveViews are swallowed
          if sandbox do
            unquote(__MODULE__).Utils.register_session_cleanup(sandbox, test_pid)
          end

          on_exit(fn ->
            # Sandbox checkin runs cleanup callbacks first, then
            # await_orphans, rollback, kill, check logs
            unquote(__MODULE__).Utils.checkin_sandbox(sandbox)
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

    def resolve_test_driver(context) do
      cond do
        # WALLABIDI_BROWSER forces all tests to a specific browser
        browser = System.get_env("WALLABIDI_BROWSER") ->
          String.to_existing_atom(browser)

        # When running inside a specific driver's test suite (e.g. WALLABIDI_DRIVER=chrome),
        # don't route to a different driver based on tags
        System.get_env("WALLABIDI_DRIVER") in ["chrome", "lightpanda"] ->
          Wallabidi.resolve_driver()

        # @tag :browser — needs full browser (Chrome)
        context[:browser] ->
          Application.get_env(:wallabidi, :browser, :chrome)

        # @tag :headless — needs a headless browser (Lightpanda or Chrome)
        context[:headless] ->
          Application.get_env(:wallabidi, :headless, :lightpanda)

        # Default — use the fastest available driver
        true ->
          Wallabidi.resolve_driver()
      end
    end

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

    @doc false
    def checkout_sandbox(async?) do
      sandbox_mod = sandbox_case_mod()

      if sandbox_mod && sandbox_mod.setup?() do
        sandbox = sandbox_mod.checkout(async?: async? || false)
        metadata = sandbox_mod.ecto_metadata(sandbox)
        {metadata, sandbox}
      else
        {maybe_checkout_repos(async?), nil}
      end
    end

    @doc false
    def register_session_cleanup(sandbox, test_pid) do
      sandbox_mod = sandbox_case_mod()

      if sandbox_mod do
        sandbox_mod.on_cleanup(sandbox, fn ->
          end_all_sessions(test_pid)
        end)
      end
    end

    @doc false
    def checkin_sandbox(nil), do: :ok

    def checkin_sandbox(sandbox) do
      sandbox_mod = sandbox_case_mod()
      if sandbox_mod, do: sandbox_mod.checkin(sandbox)
    end

    defp sandbox_case_mod do
      mod = Module.concat([SandboxCase, Sandbox])
      if Code.ensure_loaded?(mod), do: mod
    end

    if @includes_ecto do
      defp maybe_checkout_repos(async?) do
        otp_app()
        |> ecto_repos()
        |> Enum.map(&checkout_ecto_repos(&1, async?))
        |> metadata_for_ecto_repos()
      end

      defp otp_app(), do: Application.get_env(:wallabidi, :otp_app)

      defp ecto_repos(nil), do: []

      defp ecto_repos(otp_app) do
        Application.get_env(otp_app, :ecto_repos, [])
        |> Enum.filter(&repo_started?/1)
      end

      defp repo_started?(repo) do
        case Ecto.Repo.Registry.lookup(repo) do
          {_, _, _} -> true
          _ -> false
        end
      rescue
        _ -> false
      end

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
      defp maybe_checkout_repos(_), do: ""
    end

    def end_all_sessions(owner_pid) do
      Wallabidi.SessionStore.list_sessions_for(owner_pid: owner_pid)
      |> Enum.each(fn session ->
        try do
          Wallabidi.end_session(session)
        rescue
          _ -> :ok
        end
      end)
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
