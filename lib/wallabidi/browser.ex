defmodule Wallabidi.Browser do
  @moduledoc """
  The Browser module is the entrypoint for interacting with a real browser.

  By default, action only work with elements that are visible to a real user.

  ## Actions

  Actions are used to interact with form elements. All actions work with the
  query interface:

  ```html
  <label for="first_name">
    First Name
  </label>
  <input id="user_first_name" type="text" name="first_name">
  ```

  ```
  fill_in(page, Query.text_field("First Name"), with: "Grace")
  fill_in(page, Query.text_field("first_name"), with: "Grace")
  fill_in(page, Query.text_field("user_first_name"), with: "Grace")
  ```

  These queries work with any of the available actions.

  ```
  fill_in(page, Query.text_field("First Name"), with: "Chris")
  clear(page, Query.text_field("user_email"))
  click(page, Query.radio_button("Radio Button 1"))
  click(page, Query.checkbox("Checkbox"))
  click(page, Query.checkbox("Checkbox"))
  click(page, Query.option("Option 1"))
  click(page, Query.button("Some Button"))
  attach_file(page, Query.file_field("Avatar"), path: "test/fixtures/avatar.jpg")
  ```

  Actions return their parent element so that they can be chained together:

  ```
  page
  |> find(Query.css(".signup-form"), fn(form) ->
    form
    |> fill_in(Query.text_field("Name"), with: "Grace Hopper")
    |> fill_in(Query.text_field("Email"), with: "grace@hopper.com")
    |> click(Query.button("Submit"))
  end)
  ```

  ## Scoping

  Finders provide scoping like so:

  ```
  session
  |> visit("/page.html")
  |> find(Query.css(".users"))
  |> find(Query.css(".user", count: 3))
  |> List.first
  |> find(Query.css(".user-name"))
  ```

  If a callback is passed to find then the scoping will only apply to the callback
  and the parent will be passed to the next action in the chain:

  ```
  page
  |> find(Query.css(".todo-form"), fn(form) ->
    form
    |> fill_in(Query.text_field("What needs doing?"), with: "Write Wallabidi Documentation")
    |> click(Query.button("Save"))
  end)
  |> find(Query.css(".success-notification"), fn(notification) ->
    assert notification
    |> has_text?("Todo created successfully!")
  end)
  ```

  This allows you to create a test that is logically grouped together in a single pipeline.
  It also means that its easy to create re-usable helper functions without having to worry about
  chaining. You could re-write the above example like this:

  ```
  def create_todo(page, todo) do
    find(Query.css(".todo-form"), & fill_in_and_save_todo(&1, todo))
  end

  def fill_in_and_save_todo(form, todo) do
    form
    |> fill_in(Query.text_field("What needs doing?"), with: todo)
    |> click(Query.button("Save"))
  end

  def todo_was_created?(page) do
    find Query.css(page, ".success-notification"), fn(notification) ->
      assert notification
      |> has_text?("Todo created successfully!")
    end
  end

  assert page
  |> create_todo("Write Wallabidi Documentation")
  |> todo_was_created?
  ```
  """

  alias Wallabidi.CookieError
  alias Wallabidi.Element
  alias Wallabidi.ExpectationNotMetError
  alias Wallabidi.NoBaseUrlError
  alias Wallabidi.Query
  alias Wallabidi.Query.ErrorMessage
  alias Wallabidi.Session
  alias Wallabidi.StaleReferenceError

  @type t :: any()

  @typep session :: Session.t()
  @typep element :: Element.t()
  @opaque queryable ::
            Query.t()
            | Element.t()

  @type parent ::
          element
          | session
  @type opts :: Query.opts()

  @default_max_wait_time 3_000

  @doc """
  Attempts to synchronize with the browser. This is most often used to
  execute queries repeatedly until it either exceeds the time limit or
  returns a success.

  ## Note

  It is possible that this function never halts. Whenever we experience a stale
  reference error we retry the query without checking to see if we've run over
  our time. In practice we should eventually be able to query the DOM in a stable
  state. However, if this error does continue to occur it will cause wallabidi to
  loop forever (or until the test is killed by exunit).
  """
  @type sync_result :: {:ok, any()} | {:error, any()}
  @spec retry((-> sync_result), non_neg_integer()) :: sync_result()

  def retry(f, start_time \\ current_time()) do
    case f.() do
      {:ok, result} ->
        {:ok, result}

      {:error, :stale_reference} ->
        retry(f, start_time)

      {:error, :invalid_selector} ->
        {:error, :invalid_selector}

      {:error, e} ->
        if max_time_exceeded?(start_time) do
          {:error, e}
        else
          retry(f, start_time)
        end
    end
  end

  @doc """
  Fills in an element identified by `query` with `value`.

  All inputs previously present in the input field will be overridden.

  ### Examples

      page
      |> fill_in(Query.text_field("name"), with: "Chris")
      |> fill_in(Query.css("#password_field"), with: "secret42")

  ### Note

  Currently, Chrome only supports [BMP Unicode](http://www.unicode.org/roadmaps/bmp/) characters via the WebDriver `send_keys` action. Emojis are [SMP](https://www.unicode.org/roadmaps/smp/) characters and will be ignored.

  Using JavaScript is a known workaround for filling in fields with Emojis and other non-BMP characters.
  """
  @spec fill_in(parent, Query.t(), with: String.t()) :: parent
  def fill_in(%Session{} = parent, query, with: value) do
    if remote_session?(parent) do
      # Fused: one round-trip does silent clear + set_value + (on
      # phx-change forms) drain_patches. Saves two round-trips vs the
      # legacy element-op-per-step. `classify_interaction` returns
      # `:none` for non-phx-bound inputs (and `prepare_patch` returns
      # `:no_liveview` for non-LV pages downstream), so we don't need
      # an outer LV-aware gate.
      drain_idle_ms =
        if classify_interaction(parent, query, :change) != :none, do: 300, else: 0

      find_lazy(parent, query, fn element ->
        session = Wallabidi.Element.root_session(element)
        remote_client(session).fill_in(session, element, value, drain_idle_ms)
      end)
    else
      # In-process LV driver: route through Element.fill_in (no JS,
      # no W.run — driver overrides clear/set_value directly).
      find(parent, query, &Element.fill_in(&1, with: value))
    end
  end

  # CDP/BiDi clients ship element ops through W.run; the LV driver
  # doesn't have W.run and uses its own Element handle shape.
  defp remote_session?(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi}), do: true
  defp remote_session?(%Session{driver: Wallabidi.Remote.Drivers.ChromeCDP}), do: true
  defp remote_session?(%Session{driver: Wallabidi.Remote.Drivers.LightpandaCDP}), do: true
  defp remote_session?(_), do: false

  defp remote_client(%Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi}),
    do: Wallabidi.Remote.BiDi.Client

  defp remote_client(_), do: Wallabidi.Remote.CDP.Client

  # @doc """
  # Clears an input field. Input elements are looked up by id, label text, or name.
  # The element can also be passed in directly.
  # """
  @spec clear(parent, Query.t()) :: parent

  def clear(parent, query) do
    with_patch_await(parent, query, :change, fn ->
      parent
      |> find_lazy(query, &Element.clear/1)
    end)
  end

  @doc """
  Attaches a file to a file input. Input elements are looked up by id, label text,
  or name.
  """
  @spec attach_file(parent, Query.t(), path: String.t()) :: parent
  def attach_file(parent, query, path: path) do
    set_value(parent, query, :filename.absname(path))
  end

  @doc """
  Takes a screenshot of the current window.
  Screenshots are saved to a "screenshots" directory in the same directory the
  tests are run in.

  Pass `[{:name, "some_name"}]` to specify the file name. Defaults to a timestamp.
  Pass `[{:log, true}]` to log the location of the screenshot to stdout. Defaults to false.
  """
  @type take_screenshot_opt :: {:name, String.t()} | {:log, boolean}
  @spec take_screenshot(parent, [take_screenshot_opt]) :: parent

  def take_screenshot(%{driver: driver} = screenshotable, opts \\ []) do
    image_data =
      screenshotable
      |> driver.take_screenshot

    name =
      opts
      |> Keyword.get(:name, :erlang.system_time())
      |> to_string
      |> remove_illegal_characters

    path = path_for_screenshot(name)

    try do
      write_screenshot!(path, image_data)

      if opts[:log] do
        IO.puts("Screenshot taken, find it at #{build_file_url(path)}")
      end

      Map.update(screenshotable, :screenshots, [], &(&1 ++ [path]))
    rescue
      _ ->
        IO.puts("\nFailed to make a screenshot")

        screenshotable
    end
  end

  defp remove_illegal_characters(string), do: String.replace(string, ~r{<>:"/\\\?\*}, "")

  @doc """
  Gets the window handle of the current window.

  The window is either an instance of a browser tab or another operating system window.
  Getting the current window handle makes it easy to return to the window in case you
  need to switch between them.

  ## Usage

  ```elixir
  feature "can open a new tab and switch back to the original tab", %{session: session} do
    handle =
      session
      |> visit("/home")
      |> window_handle()

    path =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> assert_text("Some text")
      |> focus_window(handle)
      |> current_path()

    assert "/home" == path
  end
  ```
  """
  @spec window_handle(session :: Session.t()) :: String.t()
  def window_handle(%{driver: driver} = session) do
    {:ok, handle} = driver.window_handle(session)

    handle
  end

  @doc """
  Gets the window handles of all available windows.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "can open new tabs for external links", %{session: session} do
    handles =
      session
      |> visit("/home")
      |> click(Query.link("External Page"))
      |> click(Query.link("Another External Page"))
      |> window_handles()

    assert 3 == length(path)
  end
  ```
  """
  @spec window_handles(session :: Session.t()) :: [String.t()]
  def window_handles(%{driver: driver} = session) do
    {:ok, handles} = driver.window_handles(session)

    handles
  end

  @doc """
  Focuses the window identified by the given handle.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "can switch between different tabs", %{session: session} do
    handle =
      session
      |> visit("/home")
      |> window_handle()

    path =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> assert_text("Some text")
      |> focus_window(handle)
      |> current_path()

    assert "/home" == path
  end
  ```
  """
  @spec focus_window(session :: Session.t(), window_handle :: String.t()) :: parent
  def focus_window(%{driver: driver} = session, window_handle) do
    {:ok, _} = driver.focus_window(session, window_handle)

    session
  end

  @doc """
  Closes the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "closing a window focuses the previously focused window", %{session: session} do
    original_handle =
      session
      |> visit("/home")
      |> window_handle()

    new_handle =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> close_window()
      |> window_handle()

    assert original_handle == new_handle
  end
  ```
  """
  @spec close_window(session :: Session.t()) :: Session.t()
  def close_window(%{driver: driver} = session) do
    {:ok, _} = driver.close_window(session)

    session
  end

  @doc """
  Gets the size of the current window.

  The window is either an instance of a browser tab or another operating system window.

  This is useful for debugging responsive designs where the layout changes as the window size changes. The default window size is 1280x800.

  ## Usage

  ```elixir
  feature "gets the size of the current window", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> window_size()

    assert width == 1280
    assert height == 800
  end
  ```
  """
  @spec window_size(session :: Session.t()) :: %{
          String.t() => pos_integer,
          String.t() => pos_integer
        }
  def window_size(%{driver: driver} = session) do
    {:ok, size} = driver.get_window_size(session)

    size
  end

  @doc """
  Sets the size of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "sets the size of the window to mobile dimensions", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> resize_window(375, 667)
      |> window_size()

    assert width == 375
    assert height == 667
  end
  ```
  """
  @spec resize_window(session :: Session.t(), width :: pos_integer(), height :: pos_integer()) ::
          Session.t()
  def resize_window(%{driver: driver} = session, width, height) do
    {:ok, _} = driver.set_window_size(session, width, height)

    session
  end

  @doc """
  Maximizes the current window.

  The window is either an instance of a browser tab or another operating system window.

  For most browsers, this requires a graphical window manager to be running.

  ## Usage

  ```elixir
  feature "maximizes the window to the full size of the display", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> maximize_window()
      |> window_size()

    assert width == 1920
    assert height == 1080
  end
  ```
  """
  @spec maximize_window(session :: Session.t()) :: Session.t()
  def maximize_window(%{driver: driver} = session) do
    {:ok, _} = driver.maximize_window(session)

    session
  end

  @doc """
  Gets the position of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "gets the current display position of the window", %{session: session} do
    %{"x" => x, "y" => y} =
      session
      |> visit("/home")
      |> window_position()

    assert x == 200
    assert y == 200
  end
  ```
  """
  @spec window_position(session :: Session.t()) :: %{
          String.t() => pos_integer,
          String.t() => pos_integer
        }
  def window_position(%{driver: driver} = session) do
    {:ok, position} = driver.get_window_position(session)

    position
  end

  @doc """
  Sets the position of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "gets the current display position of the window", %{session: session} do
    %{"x" => x, "y" => y} =
      session
      |> visit("/home")
      |> move_window(500, 500)
      |> window_position()

    assert x == 500
    assert y == 500
  end
  ```
  """
  @spec move_window(session :: Session.t(), x :: pos_integer(), y :: pos_integer()) :: Session.t()
  def move_window(%{driver: driver} = session, x, y) do
    {:ok, _} = driver.set_window_position(session, x, y)

    session
  end

  @doc """
  Changes the driver focus to the frame found by query.
  """
  @spec focus_frame(parent, Query.t()) :: parent
  def focus_frame(%{driver: driver} = session, %Query{} = query) do
    session
    |> find(query, &driver.focus_frame(session, &1))
  end

  @doc """
  Changes the driver focus to the parent frame.
  """
  @spec focus_parent_frame(parent) :: parent

  def focus_parent_frame(%{driver: driver} = session) do
    {:ok, _} = driver.focus_parent_frame(session)
    session
  end

  @doc """
  Changes the driver focus to the default (top level) frame.
  """
  @spec focus_default_frame(parent) :: parent

  def focus_default_frame(%{driver: driver} = session) do
    {:ok, _} = driver.focus_frame(session, nil)
    session
  end

  @doc """
  Gets the current url of the session
  """
  @spec current_url(parent) :: String.t()

  def current_url(%Session{driver: driver} = session) do
    {:ok, url} = driver.current_url(session)
    url
  end

  @doc """
  Gets the current path of the session
  """
  @spec current_path(parent) :: String.t()

  def current_path(%Session{driver: driver} = session) do
    {:ok, path} = driver.current_path(session)
    path
  end

  @doc """
  Gets the title for the current page
  """
  @spec page_title(parent) :: String.t()

  def page_title(%Session{driver: driver} = session) do
    {:ok, title} = driver.page_title(session)
    title
  end

  @doc """
  Executes JavaScript synchronously, taking as arguments the script to execute,
  an optional list of arguments available in the script via `arguments`, and an
  optional callback function with the result of script execution as a parameter.
  """
  @spec execute_script(parent, String.t()) :: parent
  @spec execute_script(parent, String.t(), list) :: parent
  @spec execute_script(parent, String.t(), (binary() -> any())) :: parent
  @spec execute_script(parent, String.t(), list, (binary() -> any())) :: parent

  def execute_script(session, script) do
    execute_script(session, script, [])
  end

  def execute_script(session, script, arguments) when is_list(arguments) do
    execute_script(session, script, arguments, fn _ -> nil end)
  end

  def execute_script(session, script, callback) when is_function(callback) do
    execute_script(session, script, [], callback)
  end

  def execute_script(%{driver: driver} = parent, script, arguments, callback)
      when is_list(arguments) and is_function(callback) do
    {:ok, value} = driver.execute_script(parent, script, arguments)
    callback.(value)
    parent
  end

  @doc """
  Executes asynchronous JavaScript, taking as arguments the script to execute,
  an optional list of arguments available in the script via `arguments`, and an
  optional callback function with the result of script execution as a parameter.
  """
  @spec execute_script_async(parent, String.t()) :: parent
  @spec execute_script_async(parent, String.t(), list) :: parent
  @spec execute_script_async(parent, String.t(), (binary() -> any())) :: parent
  @spec execute_script_async(parent, String.t(), list, (binary() -> any())) :: parent

  def execute_script_async(session, script) do
    execute_script_async(session, script, [])
  end

  def execute_script_async(session, script, arguments) when is_list(arguments) do
    execute_script_async(session, script, arguments, fn _ -> nil end)
  end

  def execute_script_async(session, script, callback) when is_function(callback) do
    execute_script_async(session, script, [], callback)
  end

  def execute_script_async(%{driver: driver} = parent, script, arguments, callback)
      when is_list(arguments) and is_function(callback) do
    {:ok, value} = driver.execute_script_async(parent, script, arguments)
    callback.(value)
    parent
  end

  @doc """
  Sends a list of key strokes to active element. If strings are included
  then they are sent as individual keys. Special keys should be provided as a
  list of atoms, which are automatically converted into the corresponding key
  codes.

  For a list of available key codes see `Wallabidi.Helpers.KeyCodes`.

  ## Example

      iex> Wallabidi.Browser.send_keys(session, ["Example Text", :enter])
      iex> Wallabidi.Browser.send_keys(session, [:enter])
      iex> Wallabidi.Browser.send_keys(session, [:shift, :enter])

  ### Note

  Currently, Chrome only supports [BMP Unicode](http://www.unicode.org/roadmaps/bmp/) characters via the WebDriver `send_keys` action. Emojis are [SMP](https://www.unicode.org/roadmaps/smp/) characters and will be ignored.

  Using JavaScript is a known workaround for filling in fields with Emojis and other non-BMP characters.
  """
  @spec send_keys(parent, Query.t(), Element.keys_to_send()) :: parent
  @spec send_keys(parent, Element.keys_to_send()) :: parent

  def send_keys(parent, query, list) do
    with_patch_await(parent, query, :change, fn ->
      find_lazy(parent, query, fn element ->
        element
        |> Element.send_keys(list)
      end)
    end)
  end

  def send_keys(%Element{} = element, keys) do
    Element.send_keys(element, keys)
  end

  def send_keys(parent, keys) when is_binary(keys) do
    send_keys(parent, [keys])
  end

  def send_keys(%{driver: driver} = parent, keys) when is_list(keys) do
    {:ok, _} = driver.send_keys(parent, keys)
    parent
  end

  @doc """
  Retrieves the source of the current page.
  """
  @spec page_source(parent) :: String.t()

  def page_source(%Session{driver: driver} = session) do
    {:ok, source} = driver.page_source(session)
    source
  end

  @doc """
  Sets the value of an element. The allowed type for the value depends on the
  type of the element. The value may be:
  * a string of characters for a text element
  * :selected for a radio button, checkbox or select list option
  * :unselected for a checkbox
  """
  @spec set_value(parent, Query.t(), Element.value()) :: parent

  def set_value(parent, query, :selected) do
    if remote_session?(get_session(parent)) do
      find_lazy(parent, query, fn element ->
        session = Wallabidi.Element.root_session(element)
        remote_client(session).set_checked(session, element, true)
      end)
    else
      find(parent, query, fn element ->
        case Element.selected?(element) do
          true -> :ok
          false -> Element.click(element)
        end
      end)
    end
  end

  def set_value(parent, query, :unselected) do
    if remote_session?(get_session(parent)) do
      find_lazy(parent, query, fn element ->
        session = Wallabidi.Element.root_session(element)
        remote_client(session).set_checked(session, element, false)
      end)
    else
      find(parent, query, fn element ->
        case Element.selected?(element) do
          false -> :ok
          true -> Element.click(element)
        end
      end)
    end
  end

  def set_value(parent, query, value) do
    find_lazy(parent, query, fn element ->
      element
      |> Element.set_value(value)
    end)
  end

  @doc """
  Clicks the mouse on the element returned by the query or at the current mouse cursor position.
  """
  @spec click(parent, :left | :middle | :right) :: parent
  @spec click(parent, Query.t()) :: parent
  def click(parent, button) when button in [:left, :middle, :right] do
    case parent.driver.click(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  def click(parent, query) do
    session = get_session(parent)

    # Lightpanda: route through CDPClient.click_aware which captures
    # pre_page_id, classifies, clicks, awaits page_ready — same shape
    # as do_post_click but in one native call. Avoids the post-click
    # `find` polling fallback that cost LP ~3s per submit-form click.
    #
    # Chrome CDP / BiDi: Element.click → driver.click → click_aware
    # already handles classify + patch-await + navigation/page-ready.
    # No outer with_patch_await needed — wrapping it would double-wait.
    if session && session.driver == Wallabidi.Remote.Drivers.LightpandaCDP &&
         not in_frame?(session) && not in_switched_window?(session) do
      v2_click_with_await(parent, query)
    else
      parent |> find(query, &Element.click/1)
    end
  end

  # click path: find the element, then route the click through
  # CDPClient.click_aware which:
  #   1. captures pre_page_id from the bootstrap
  #   2. classifies the click (patch / navigate / full_page / none)
  #   3. dispatches the click via JS
  #   4. for non-"none" classifications, awaits the bootstrap's
  #      page_ready notification on the new document (push-based, no
  #      polling)
  defp v2_click_with_await(parent, query) do
    # Use find_lazy: click_aware does two element ops on the result and
    # discards it. Lazy saves the ref-fetch round-trip at find time
    # (the V8 ref isn't needed — each subsequent op re-resolves via the
    # spliced query+target ops in W.run).
    case find_lazy(parent, query) do
      %Wallabidi.Element{} = element ->
        case v2_click_module(element.parent).click_aware(element.parent, element) do
          {:ok, _classification} ->
            parent

          {:error, :timeout} ->
            # Page-ready timeout: the click ran but no page_ready
            # arrived. Fall through; subsequent assertions will retry
            # via their own polling.
            parent

          {:error, _} ->
            find_lazy(parent, query, &Element.click/1)
            parent
        end

      _ ->
        parent |> find_lazy(query, &Element.click/1)
    end
  end

  # Pick the client module that owns a given session's transport.
  # CDP and BiDi expose the same `click_aware/2` shape, so callers
  # can invoke `mod.click_aware(...)` uniformly.
  defp v2_click_module(%Wallabidi.Session{driver: Wallabidi.Remote.Drivers.ChromeBiDi}),
    do: Wallabidi.Remote.BiDi.Client

  defp v2_click_module(_), do: Wallabidi.Remote.CDP.Client

  @doc """
  Double-clicks left mouse button at the current mouse coordinates.
  """
  @spec double_click(parent) :: parent
  def double_click(parent) do
    case parent.driver.double_click(parent) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
   Clicks and holds the given mouse button at the current mouse coordinates.
  """
  @spec button_down(parent, atom) :: parent
  def button_down(parent, button \\ :left) when button in [:left, :middle, :right] do
    case parent.driver.button_down(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
   Releases given previously held mouse button.
  """
  @spec button_up(parent, atom) :: parent
  def button_up(parent, button \\ :left) when button in [:left, :middle, :right] do
    case parent.driver.button_up(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
  Hovers over an element.
  """
  @spec hover(parent, Query.t()) :: parent
  def hover(parent, query) do
    parent
    |> find(query, &Element.hover/1)
  end

  @doc """
  Moves mouse by an offset relative to current cursor position.
  """
  @spec move_mouse_by(parent, integer, integer) :: parent
  def move_mouse_by(parent, x_offset, y_offset) do
    case parent.driver.move_mouse_by(parent, x_offset, y_offset) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
  Touches the screen at the given position.
  """
  @spec touch_down(parent, integer, integer) :: session

  def touch_down(parent, x, y) when is_integer(x) and is_integer(y) do
    case parent.driver.touch_down(parent, nil, x, y) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
  Touches and holds the element on its top-left corner plus an optional offset.
  """
  @spec touch_down(parent, Query.t(), integer, integer) :: session

  def touch_down(parent, query, x_offset \\ 0, y_offset \\ 0) do
    parent
    |> find(query, &Element.touch_down(&1, x_offset, y_offset))
  end

  @doc """
  Stops touching the screen.
  """
  @spec touch_up(parent) :: parent

  def touch_up(parent) do
    case parent.driver.touch_up(parent) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
  Taps the element.
  """
  @spec tap(parent, Query.t()) :: session

  def tap(parent, query) do
    parent
    |> find(query, &Element.tap/1)
  end

  @doc """
  Moves the touch pointer (finger, stylus etc.) on the screen to the point determined by the given coordinates.
  """
  @spec touch_move(parent, non_neg_integer, non_neg_integer) :: parent

  def touch_move(parent, x, y) do
    case parent.driver.touch_move(parent, x, y) do
      {:ok, _} ->
        parent
    end
  end

  @doc """
  Scroll on the screen from the given element by the given offset using touch events.
  """
  @spec touch_scroll(parent, Query.t(), integer, integer) :: parent

  def touch_scroll(parent, query, x, y) do
    parent
    |> find(query, &Element.touch_scroll(&1, x, y))
  end

  @doc """
  Gets the Element's text value.

  If the element is not visible, the return value will be `""`.
  """
  @spec text(parent) :: String.t()
  @spec text(parent, Query.t()) :: String.t()
  def text(parent, query) do
    parent
    |> find_lazy(query)
    |> Element.text()
  end

  def text(%Session{} = session) do
    session
    |> find_lazy(Query.css("body"))
    |> Element.text()
  end

  @doc """
  Gets the value of the elements attribute.
  """
  @spec attr(parent, Query.t(), String.t()) :: String.t() | nil
  def attr(parent, query, name) do
    parent
    |> find_lazy(query)
    |> Element.attr(name)
  end

  @doc """
  Checks if the element has been selected. Alias for checked?(element)
  """
  @spec selected?(parent, Query.t()) :: boolean()
  def selected?(parent, query) do
    parent
    |> find_lazy(query)
    |> Element.selected?()
  end

  @doc """
  Checks if the element is visible on the page
  """
  @spec visible?(parent, Query.t()) :: boolean()
  def visible?(parent, query) do
    parent
    |> has?(query)
  end

  @doc """
  Finds and returns one or more DOM element(s) on the page based on the given query.

  The query is scoped by the first argument, which is either the `%Session{}` or an
  `%Element{}`.

  ## Example

  ```elixir
  session
  |> find(Query.css("#login-button"))
  |> assert_text("Login")

  buttons =
    session
    |> find(Query.css(".login-button", count: 2, text: "Login"))
  ```

  ## Notes

  - Blocks until it finds the element(s) or the max time is reached.
  - By default only 1 element is expected to match the query. If more elements are present then a count can be
    specified. Use `count: :any` to allow any number of elements to be present.
  - By default only elements that would be visible to a real user on the page are returned.
  """
  @spec find(parent, Query.t()) :: Element.t() | [Element.t()]
  def find(parent, %Query{} = query) do
    do_find(parent, query, current_time())
  end

  # Callback form of find_lazy/2: mirrors find/3 but elements are lazy.
  # Caller's callback runs against the lazy element and the parent is
  # returned for piping. The callback may invoke any Element op that
  # routes through call_on_element — pointer/touch ops and frame focus
  # need eager refs and should not be on the lazy path.
  defp find_lazy(parent, %Query{} = query, callback) when is_function(callback) do
    results = find_lazy(parent, query)
    callback.(results)
    parent
  end

  # Internal find that returns lazy Elements (no V8 ref-fetch round
  # trip). Use only when the caller will discard the elements after
  # one or two ops — e.g. Browser.text/2, attr/3. Subsequent ops on
  # lazy elements re-resolve via [query, target N] inside W.run.
  #
  # Falls back to eager find on drivers that don't support the ops
  # pipeline (LiveView driver), since the lazy path requires the
  # W.run interpreter on the page.
  defp find_lazy(parent, %Query{} = query) do
    session = get_session(parent)

    if session &&
         session.driver in [
           Wallabidi.Remote.Drivers.LightpandaCDP,
           Wallabidi.Remote.Drivers.ChromeCDP,
           Wallabidi.Remote.Drivers.ChromeBiDi
         ] && not in_frame?(session) && not in_switched_window?(session) do
      do_find_lazy(parent, query, current_time())
    else
      do_find(parent, query, current_time())
    end
  end

  defp do_find_lazy(parent, query, start_time),
    do: do_find_with(parent, query, start_time, lazy: true)

  # The find path can return :stale_reference when a concurrent
  # navigation cleared `window.__w.queries` between the count
  # notification and the element fetch, OR when the find itself timed
  # out but the elements actually exist (sync recheck found > 0). In
  # both cases the right move is to re-run the whole query against the
  # current page — the query budget bounds the total wait.
  defp do_find(parent, query, start_time),
    do: do_find_with(parent, query, start_time, [])

  # Single retry loop shared by do_find and do_find_lazy. Differs only
  # in the `opts` passed to execute_query (lazy: true for the lazy
  # path).
  defp do_find_with(parent, query, start_time, opts) do
    case execute_query(parent, query, opts) do
      {:ok, query} ->
        Query.result(query)

      {:error, :stale_reference} ->
        if max_time_exceeded?(start_time) do
          raise Wallabidi.QueryError, ErrorMessage.message(query, :not_found)
        else
          do_find_with(parent, query, start_time, opts)
        end

      {:error, {:not_found, result}} ->
        query = %{query | result: result}

        case validate_html(parent, query) do
          {:ok, _} ->
            raise Wallabidi.QueryError, ErrorMessage.message(query, :not_found)

          {:error, html_error} ->
            raise Wallabidi.QueryError, ErrorMessage.message(query, html_error)
        end

      {:error, e} ->
        raise Wallabidi.QueryError, ErrorMessage.message(query, e)
    end
  end

  @doc """
  Same as `find/2`, but takes a callback to enact side effects on the found element(s).

  ## Example

  ```elixir
  session
  |> find(Query.css("#login-button"), fn button ->
    assert_text(button, "Login")
  end)

  session
  |> find(Query.css(".login-button", count: 2, text: "Login"), fn buttons ->
    assert 2 == length(buttons)
  end)

  ```

  ## Notes

  - Returns the first argument to make the function pipe-able.
  """
  @spec find(parent, Query.t(), (Element.t() -> any())) :: parent
  def find(parent, %Query{} = query, callback) when is_function(callback) do
    results = find(parent, query)
    callback.(results)

    parent
  end

  @doc """
  Finds all of the DOM elements that match the CSS selector. If no elements are
  found then an empty list is immediately returned. This is equivalent to calling
  `find(session, css("element", count: nil, minimum: 0))`.
  """
  @spec all(parent, Query.t()) :: [Element.t()]
  def all(parent, %Query{} = query) do
    find(
      parent,
      %{query | conditions: Keyword.merge(query.conditions, count: nil, minimum: 0)}
    )
  end

  @doc """
  Validates that the query returns a result. This can be used to define other
  types of matchers.
  """
  @spec has?(parent, Query.t()) :: boolean()
  def has?(parent, query) do
    case execute_query(parent, query) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Matches the Element's value with the provided value.
  """
  @spec has_value?(parent, Query.t(), any()) :: boolean()
  @spec has_value?(Element.t(), any()) :: boolean()
  def has_value?(parent, query, value) do
    parent
    |> find_lazy(query)
    |> has_value?(value)
  end

  def has_value?(%Element{} = element, value) do
    session = Wallabidi.Element.root_session(element)

    if remote_session?(session) do
      case remote_client(session).await_value(session, element, value, max_wait_time()) do
        {:ok, true} -> true
        _ -> false
      end
    else
      retry_match(fn -> Element.value(element) == value end)
    end
  end

  defp retry_match(predicate) do
    case retry(fn ->
           if predicate.(), do: {:ok, true}, else: {:error, false}
         end) do
      {:ok, true} -> true
      _ -> false
    end
  end

  @doc """
  Matches the parent's content with the provided text.

  Returns a boolean that indicates if the text was found.

  ## Examples

  ```
  session
  |> visit("/")
  |> has_text?("Login")
  ```

  Example providing query:

  ```
  session
  |> visit("/")
  |> has_text?(Query.css(".login-button"), "Login")
  ```
  """
  @spec has_text?(parent, String.t()) :: boolean()
  @spec has_text?(parent, Query.t(), String.t()) :: boolean()
  def has_text?(parent, query, text) do
    parent
    |> find_lazy(query)
    |> has_text?(text)
  end

  def has_text?(%Session{} = session, text) when is_binary(text) do
    session
    |> find_lazy(Query.css("body"))
    |> has_text?(text)
  end

  def has_text?(%Element{} = element, text) when is_binary(text) do
    session = Wallabidi.Element.root_session(element)

    if remote_session?(session) do
      # Single-RT await: V8 polls textContent with MutationObserver +
      # onPatchEnd until match or timeout. Replaces an Elixir-side
      # retry loop that polled Element.text every 25ms.
      case remote_client(session).await_text(session, element, text, max_wait_time()) do
        {:ok, true} -> true
        _ -> false
      end
    else
      retry_match(fn -> Element.text(element) =~ text end)
    end
  end

  @doc """
  Matches the Element's content with the provided text and raises if not found.

  Returns the given `parent` if the assertion is correct so that it is easily
  pipeable.

  ## Examples

  ```
  session
  |> visit("/")
  |> assert_text("Login")
  ```

  Example providing query:

  ```
  session
  |> visit("/")
  |> assert_text(Query.css(".login-button"), "Login")
  ```
  """
  @spec assert_text(parent, String.t()) :: parent
  @spec assert_text(parent, Query.t(), String.t()) :: parent
  def assert_text(parent, query, text) when is_binary(text) do
    parent
    |> find_lazy(query)
    |> assert_text(text)
  end

  def assert_text(parent, text) when is_binary(text) do
    if has_text?(parent, text) do
      parent
    else
      raise ExpectationNotMetError, "Text '#{text}' was not found."
    end
  end

  @doc """
  Checks if `query` is present within `parent` and raises if not found.

  Returns the given `parent` if the assertion is correct so that it is easily
  pipeable.

  ## Examples

      session
      |> visit("/")
      |> assert_has(Query.css(".login-button"))
  """

  defmacro assert_has(parent, query) do
    quote do
      parent = unquote(parent)
      query = unquote(query)

      case execute_query(parent, query) do
        {:ok, _query_result} ->
          parent

        error ->
          case error do
            {:error, {:not_found, results}} ->
              query = %{query | result: results}

              raise ExpectationNotMetError,
                    Query.ErrorMessage.message(query, :not_found)

            {:error, e} ->
              raise Wallabidi.QueryError,
                    Query.ErrorMessage.message(query, e)

            _ ->
              raise Wallabidi.ExpectationNotMetError,
                    "Wallabidi has encountered an internal error: #{inspect(error)} with session: #{inspect(parent)}"
          end
      end
    end
  end

  @doc """
  Checks if `query` is not present within `parent` and raises if it is found.

  Returns the given `parent` if the query is not found so that it is easily
  pipeable.

  ## Examples

      session
      |> visit("/")
      |> refute_has(Query.css(".secret-admin-content"))
  """
  defmacro refute_has(parent, query) do
    quote do
      parent = unquote(parent)
      query = unquote(query)

      case execute_query(parent, query) do
        {:error, :invalid_selector} ->
          raise Wallabidi.QueryError,
                Query.ErrorMessage.message(query, :invalid_selector)

        {:error, _not_found} ->
          parent

        {:ok, query} ->
          raise Wallabidi.ExpectationNotMetError,
                Query.ErrorMessage.message(query, :found)
      end
    end
  end

  @doc """
  Searches for CSS on the page.
  """
  @spec has_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_css?(parent, String.t()) :: boolean()
  def has_css?(parent, query, css) when is_binary(css) do
    parent
    |> find(query)
    |> has?(Query.css(css, count: :any))
  end

  def has_css?(parent, css) when is_binary(css) do
    parent
    |> has?(Query.css(css, count: :any))
  end

  @doc """
  Searches for CSS that should not be on the page
  """
  @spec has_no_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_no_css?(parent, String.t()) :: boolean()
  def has_no_css?(parent, query, css) when is_binary(css) do
    parent
    |> find(query)
    |> has?(Query.css(css, count: 0))
  end

  def has_no_css?(parent, css) when is_binary(css) do
    parent
    |> has?(Query.css(css, count: 0))
  end

  @doc """
  Changes the current page to the provided route.
  Relative paths are appended to the provided base_url.
  Absolute paths do not use the base_url.
  """
  @spec visit(session, String.t()) :: session
  def visit(%Session{driver: driver} = session, path) do
    uri = URI.parse(path)

    cond do
      uri.host == nil && String.length(base_url()) == 0 ->
        raise NoBaseUrlError, path

      uri.host ->
        driver.visit(session, path)

      true ->
        driver.visit(session, request_url(path))
    end

    session
  end

  def cookies(%Session{driver: driver} = session) do
    {:ok, cookies_list} = driver.cookies(session)

    cookies_list
  end

  def set_cookie(%Session{driver: driver} = session, key, value, attributes \\ []) do
    if blank_page?(session) do
      raise CookieError
    end

    case driver.set_cookie(session, key, value, attributes) do
      {:ok, _list} ->
        session

      {:error, :invalid_cookie_domain} ->
        raise CookieError
    end
  end

  defp blank_page?(%Session{driver: driver} = session) do
    driver.blank_page?(session)
  end

  @doc """
  Accepts one alert dialog, which must be triggered within the specified `fun`.
  Returns the message that was presented to the user. For example:

  ```
  message = accept_alert session, fn(s) ->
    click(s, Query.link("Trigger alert"))
  end
  ```
  """
  def accept_alert(%Session{driver: driver} = session, fun) do
    driver.accept_alert(session, fun)
  end

  @doc """
  Accepts one confirmation dialog, which must be triggered within the specified
  `fun`. Returns the message that was presented to the user. For example:

  ```
  message = accept_confirm session, fn(s) ->
    click(s, Query.link("Trigger confirm"))
  end
  ```
  """
  def accept_confirm(%Session{driver: driver} = session, fun) do
    driver.accept_confirm(session, fun)
  end

  @doc """
  Dismisses one confirmation dialog, which must be triggered within the
  specified `fun`. Returns the message that was presented to the user. For
  example:

  ```
  message = dismiss_confirm session, fn(s) ->
    click(s, Query.link("Trigger confirm"))
  end
  ```
  """
  def dismiss_confirm(%Session{driver: driver} = session, fun) do
    driver.dismiss_confirm(session, fun)
  end

  @doc """
  Accepts one prompt, which must be triggered within the specified `fun`. The
  `[with: value]` option allows to simulate user input for the prompt. If no
  value is provided, the default value that was passed to `window.prompt` will
  be used instead. Returns the message that was presented to the user. For
  example:

  ```
  message = accept_prompt session, fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```

  Example providing user input:

  ```
  message = accept_prompt session, [with: "User input"], fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```
  """
  def accept_prompt(%Session{} = session, fun) do
    do_accept_prompt(session, nil, fun)
  end

  def accept_prompt(%Session{} = session, [with: input_value], fun) when is_binary(input_value) do
    do_accept_prompt(session, input_value, fun)
  end

  defp do_accept_prompt(%Session{driver: driver} = session, input_value, fun) do
    driver.accept_prompt(session, input_value, fun)
  end

  @doc """
  Dismisses one prompt, which must be triggered within the specified `fun`.
  Returns the message that was presented to the user. For example:

  ```
  message = dismiss_prompt session, fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```
  """
  def dismiss_prompt(%Session{driver: driver} = session, fun) do
    driver.dismiss_prompt(session, fun)
  end

  defp validate_html(parent, %{html_validation: :button_type} = query) do
    buttons = all(parent, Query.css("button", text: query.selector))

    if Enum.count(buttons) == 1 do
      {:error, :button_with_bad_type}
    else
      {:ok, query}
    end
  end

  defp validate_html(parent, %{html_validation: :bad_label} = query) do
    label_query = Query.css("label", text: query.selector)
    labels = all(parent, label_query)

    case labels do
      [label] ->
        for_attr = Element.attr(label, "for")

        error =
          if for_attr == nil do
            :label_with_no_for
          else
            id_query = Query.css("[id='#{for_attr}']", count: :any)
            matching_id_count = parent |> all(id_query) |> Enum.count()

            {:label_does_not_find_field, for_attr, matching_id_count}
          end

        {:error, error}

      _ ->
        {:ok, query}
    end
  end

  defp validate_html(_, query), do: {:ok, query}

  defp validate_visibility(query, elements) do
    case Query.visible?(query) do
      :any ->
        {:ok, elements}

      true ->
        {:ok, Enum.filter(elements, &Element.visible?(&1))}

      false ->
        {:ok, Enum.reject(elements, &Element.visible?(&1))}
    end
  end

  defp validate_selected(query, elements) do
    case Query.selected?(query) do
      :any ->
        {:ok, elements}

      true ->
        {:ok, Enum.filter(elements, &Element.selected?(&1))}

      false ->
        {:ok, Enum.reject(elements, &Element.selected?(&1))}
    end
  end

  defp validate_count(query, elements) do
    if Query.matches_count?(query, Enum.count(elements)) do
      {:ok, elements}
    else
      {:error, {:not_found, elements}}
    end
  end

  defp do_at(query, elements) do
    case {Query.at_number(query), length(elements)} do
      {:all, _} ->
        {:ok, elements}

      {n, count} when n < count ->
        {:ok, [Enum.at(elements, n)]}

      {_, _} ->
        {:error, {:not_found, elements}}
    end
  end

  defp validate_text(query, elements) do
    text = Query.inner_text(query)

    if text do
      {:ok, Enum.filter(elements, &matching_text?(&1, text))}
    else
      {:ok, elements}
    end
  end

  defp matching_text?(%Element{driver: driver} = element, text) do
    case driver.text(element) do
      {:ok, element_text} ->
        element_text =~ ~r/#{Regex.escape(text)}/

      {:error, _} ->
        false
    end
  end

  def execute_query(parent, query, opts \\ [])

  def execute_query(%{driver: driver} = parent, query, opts) do
    session = get_session(parent)

    # CDP and BiDi both use the ops pipeline for find+filter in one
    # eval. Push-based: CDP uses Runtime.addBinding, BiDi uses
    # script.channel. The in-frame / switched-window cases keep the
    # legacy element-by-element path until the pipeline is taught
    # about frame scoping.
    if session && remote_session?(session) &&
         not in_frame?(session) && not in_switched_window?(session) do
      execute_query_pipeline(parent, driver, query, opts)
    else
      execute_query_legacy(parent, driver, query)
    end
  end

  # Ops pipeline: compile find + visibility/text/selected filters into one
  # JS evaluation. Both CDP and BiDi use push-based find:
  # CDP: Runtime.addBinding → Runtime.bindingCalled
  # BiDi: script.addPreloadScript channel → script.message
  defp execute_query_pipeline(parent, _driver, query, opts) do
    alias Wallabidi.Remote.CDP.Ops

    session = get_session(parent)
    lazy? = Keyword.get(opts, :lazy, false)

    with {:ok, _ops, validated} <- Ops.from_wallaby(parent, query) do
      timeout = query_timeout(validated)

      result =
        cond do
          session.driver == Wallabidi.Remote.Drivers.ChromeBiDi and lazy? ->
            Wallabidi.Remote.BiDi.Client.find_elements_lazy(parent, validated, timeout: timeout)

          session.driver == Wallabidi.Remote.Drivers.ChromeBiDi ->
            # BiDi: push-based bootstrap pipeline speaking BiDi.
            Wallabidi.Remote.BiDi.Client.find_elements(parent, validated, timeout: timeout)

          session.driver in [
            Wallabidi.Remote.Drivers.LightpandaCDP,
            Wallabidi.Remote.Drivers.ChromeCDP
          ] and
              lazy? ->
            Wallabidi.Remote.CDP.Client.find_elements_lazy(parent, validated, timeout: timeout)

          session.driver in [
            Wallabidi.Remote.Drivers.LightpandaCDP,
            Wallabidi.Remote.Drivers.ChromeCDP
          ] ->
            # CDP: same push pipeline routed through Session.
            Wallabidi.Remote.CDP.Client.find_elements(parent, validated, timeout: timeout)
        end

      case result do
        {:ok, elements} ->
          with {:ok, elements} <- validate_count(validated, elements),
               {:ok, elements} <- do_at(validated, elements) do
            {:ok, %{validated | result: elements}}
          end

        error ->
          error
      end
    end
  end

  defp execute_query_legacy(parent, driver, query) do
    retry(fn ->
      try do
        with {:ok, query} <- Query.validate(query),
             compiled_query <- Query.compile(query),
             {:ok, elements} <- driver.find_elements(parent, compiled_query),
             {:ok, elements} <- validate_visibility(query, elements),
             {:ok, elements} <- validate_text(query, elements),
             {:ok, elements} <- validate_selected(query, elements),
             {:ok, elements} <- validate_count(query, elements),
             {:ok, elements} <- do_at(query, elements) do
          {:ok, %{query | result: elements}}
        end
      rescue
        StaleReferenceError ->
          {:error, :stale_reference}
      end
    end)
  end

  defp get_session(%Session{} = s), do: s
  defp get_session(%Element{parent: p}), do: get_session(p)
  defp get_session(_), do: nil

  defp in_frame?(%Session{} = session) do
    Process.get({:cdp_frame_stack, session.id}, []) != [] or
      Process.get({:wallabidi_frame_context, session.id}) != nil
  end

  defp in_switched_window?(%Session{} = session) do
    Process.get({:cdp_current_target, session.id}) != nil or
      Process.get({:wallabidi_focused_context, session.id}) != nil
  end

  defp max_time_exceeded?(start_time) do
    current_time() - start_time > max_wait_time()
  end

  defp current_time do
    :erlang.monotonic_time(:milli_seconds)
  end

  defp max_wait_time do
    Application.get_env(:wallabidi, :max_wait_time, @default_max_wait_time)
  end

  # `all/2` and similar snapshot queries set `minimum: 0`. They want the
  # current matches now, not "wait until something appears." Skip the
  # full max_wait_time budget for those — fall through to the inline
  # sync-count branch quickly.
  defp query_timeout(%Wallabidi.Query{conditions: conditions}) do
    if Keyword.get(conditions, :minimum) == 0,
      do: 50,
      else: max_wait_time()
  end

  defp request_url(path) do
    base_url = String.trim_trailing(base_url(), "/")
    path = String.trim_leading(path, "/")

    "#{base_url}/#{path}"
  end

  defp base_url do
    Application.get_env(:wallabidi, :base_url) || ""
  end

  defp path_for_screenshot(name) do
    "#{screenshot_dir()}/#{name}.png"
  end

  defp write_screenshot!(path, image_data) do
    expanded_path = Path.expand(path)
    :ok = expanded_path |> Path.dirname() |> File.mkdir_p!()

    :ok = File.write!(expanded_path, image_data)

    :ok
  end

  defp screenshot_dir do
    Application.get_env(:wallabidi, :screenshot_dir, "#{File.cwd!()}/screenshots")
  end

  @doc """
  Waits for the next LiveView DOM patch.

  Installed automatically via JavaScript — no `app.js` changes needed.

  `click/2` and `fill_in/3` call this automatically. Use `await_patch`
  explicitly for patches triggered by something other than a direct
  interaction (e.g. PubSub broadcast, timer).

  ## Options

  * `:timeout` — max wait in ms (default: 5_000)

  ## Examples

      # Wait for a PubSub-triggered update
      Phoenix.PubSub.broadcast(MyApp.PubSub, "updates", :refresh)
      session
      |> await_patch()
      |> assert_has(Query.css(".updated"))
  """
  @spec await_patch(session, keyword()) :: session
  def await_patch(%Session{driver: driver} = session, opts \\ []) do
    driver.await_patch(session, opts)
    session
  end

  # Wraps an interaction with prepare_patch/await_patch.
  # Sets up the promise before the action, awaits after.
  # Skips if: not BiDi, no LiveView, or the element is a JS-only click
  # (phx-click without a push command, e.g. JS.toggle).
  defp with_patch_await(%Session{} = session, query, interaction, fun) do
    # Only remote sessions can run JS for classification. The in-process
    # LV driver renders synchronously and has no patch lifecycle to
    # await — `fun.()` is the right answer there.
    if remote_session?(session) do
      case classify_interaction(session, query, interaction) do
        :patch ->
          do_patch_await(session, fun)

        :navigate ->
          do_navigate_await(session, fun)

        :full_page ->
          result = fun.()
          Wallabidi.SessionProcess.await_next_page_load(session)
          Wallabidi.Remote.LiveViewAware.await_liveview_connected(session)
          result

        :none ->
          fun.()
      end
    else
      fun.()
    end
  end

  defp with_patch_await(_parent, _query, _interaction, fun), do: fun.()

  # Classify the interaction: :patch, :navigate, :full_page, or :none.
  defp do_patch_await(session, fun) do
    case Wallabidi.Remote.LiveViewAware.prepare_patch(session) do
      :prepared ->
        result = fun.()

        case Wallabidi.Remote.LiveViewAware.await_patch(session) do
          :ok ->
            result

          :timeout ->
            result

          :page_navigated ->
            Wallabidi.SessionProcess.await_next_page_load(session)
            Wallabidi.Remote.LiveViewAware.await_liveview_connected(session)
            result
        end

      :no_liveview ->
        fun.()
    end
  end

  defp do_navigate_await(session, fun) do
    # We already know this is a navigation (push_navigate / redirect), not
    # a patch. Don't await_patch — its fixed 5s timeout fires before the
    # slow navigation completes under load, adding pure dead time. Instead
    # go straight to waiting for the new LiveView to connect (which waits
    # for the URL to change first via the pre_url check).
    {:ok, pre_url} = Wallabidi.Remote.Protocol.current_url(session)
    result = fun.()
    Wallabidi.Remote.LiveViewAware.await_liveview_connected(session, pre_url: pre_url)
    result
  end

  # :patch     — phx-click, phx-submit, phx-change, <.link patch=...>
  # :navigate  — <.link navigate=...> (data-phx-link="redirect")
  # :full_page — plain <a href="..."> (full HTTP navigation)
  # :none      — no LiveView binding, no link
  defp classify_interaction(session, query, interaction) do
    with {:ok, validated} <- Query.validate(query),
         compiled <- Query.compile(validated) do
      case compiled do
        {:css, selector} ->
          check_phx_binding(session, selector, interaction)

        {:xpath, xpath} ->
          check_phx_binding_xpath(session, xpath, interaction)
      end
    else
      _ -> :none
    end
  end

  # Both check_phx_binding/* delegate to W.run via a [query, classify_first]
  # opcode pipeline. The single source of truth for the classifier is
  # `W.classify` in priv/wallabidi.js — the page-side interpreter
  # exposes it via the `classify_first` accumulator op.
  defp check_phx_binding(session, selector, interaction),
    do: classify_via_query(session, "css", selector, interaction)

  defp check_phx_binding_xpath(session, xpath, interaction),
    do: classify_via_query(session, "xpath", xpath, interaction)

  defp classify_via_query(session, query_type, selector, interaction) do
    ops_json =
      Jason.encode!([
        ["query", query_type, selector],
        ["classify_first", to_string(interaction)]
      ])

    js = "window.__w.run(#{ops_json}, null).meta.classification"

    case Wallabidi.Remote.Protocol.eval(session, js) do
      {:ok, result} -> parse_classification(result)
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp parse_classification("navigate"), do: :navigate
  defp parse_classification("full_page"), do: :full_page
  defp parse_classification("patch"), do: :patch
  defp parse_classification("none"), do: :none
  # If classification JS failed or returned something unexpected, don't
  # default to :patch — that adds a 5s await_patch timeout for no reason.
  # Safer to skip the wait and let the normal retry loop handle it.
  defp parse_classification(_), do: :none

  @doc false
  def build_file_url(path) do
    "file://" <> (path |> Path.expand() |> URI.encode())
  end
end
