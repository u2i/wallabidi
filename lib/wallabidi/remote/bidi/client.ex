defmodule Wallabidi.Remote.BiDi.Client do
  @moduledoc false

  # BiDi-flavored counterpart to CDPClient.
  #
  # Same operation surface (visit, find_elements, click, evaluate,
  # text, attribute, ...) but every wire call goes out as a
  # WebDriver-BiDi command instead of CDP. The Transport.Protocol
  # layer is unchanged — both clients dispatch through the session's
  # actor pid.
  #
  # Implements `Wallabidi.Remote.WireProtocol` directly — driver Specs
  # point `wire_protocol: BiDiClient` and the Orchestrator dispatches
  # straight to these functions, no adapter wrapper in between.

  @behaviour Wallabidi.Remote.WireProtocol

  alias Wallabidi.Element
  alias Wallabidi.Remote.BiDi.{Commands, ResponseParser}
  alias Wallabidi.Remote.Bootstrap
  alias Wallabidi.Remote.OpsShared
  alias Wallabidi.Remote.Transport.Protocol
  alias Wallabidi.Session

  # Pulls in shared op bodies (text/2, attribute/3, displayed/2,
  # click/2, set_value_dom/3, clear/2, send_keys_text/3, page-info
  # ops). They call this module's call_on_element/4 + evaluate/2,3
  # for the wire layer.
  use Wallabidi.Remote.OpsShared

  # Frame focus stores an override in the test process dictionary
  # (BiDi V2BiDiDriver.focus_frame writes it). When set, subsequent
  # BiDi commands target the focused iframe's browsing context
  # instead of the session struct's root one. Per-process so that
  # concurrent tests don't interfere.
  defp ctx(%Session{id: id, browsing_context: root}) do
    case Process.get({:wallabidi_bidi_v2_frame, id}) do
      nil -> root
      override when is_binary(override) -> override
    end
  end

  # ----- Navigation -----

  @doc """
  Navigate the session's browsing context to `url`. Returns
  `{:ok, %{loader_id: id_or_nil}}` — the BiDi `navigation` id is the
  correlation key the caller passes to
  `Transport.Protocol.await_page_load/4`.

  Uses `wait: "none"` so the call returns as soon as the navigation
  is committed. Awaiting load milestones is the caller's job — see
  the higher-level `visit/3` from `OpsShared`.
  """
  @spec navigate(Session.t(), String.t()) ::
          {:ok, %{loader_id: String.t() | nil}} | {:error, term}
  def navigate(%Session{} = session, url) when is_binary(url) do
    case Protocol.cdp_send(
           session,
           "browsingContext.navigate",
           %{"context" => ctx(session), "url" => url, "wait" => "none"},
           []
         ) do
      {:ok, %{"navigation" => nav}} ->
        {:ok, %{loader_id: nav}}

      {:ok, _} = unexpected ->
        {:error, {:unexpected_navigate_response, unexpected}}

      error ->
        error
    end
  end

  # visit/3 — provided by Wallabidi.Remote.OpsShared (uses our navigate/2).

  # ----- Script evaluation -----

  @doc """
  Evaluate a JS expression in the current browsing context's realm.
  Returns the deserialized value.

  When `args` is empty, treats `expression` as a raw expression
  (BiDi `script.evaluate`). When args are provided OR the
  expression contains a `return`, wraps it in a function and uses
  `script.callFunction` so `return` and `arguments[]` references
  work like the user-facing `execute_script` API expects.
  """
  @spec evaluate(Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression) when is_binary(expression) do
    do_eval_expression(session, expression)
  end

  @spec evaluate(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}
  def evaluate(%Session{} = session, expression, args)
      when is_binary(expression) and is_list(args) do
    if needs_wrap?(expression, args) do
      do_eval_function(session, expression, args)
    else
      do_eval_expression(session, expression)
    end
  end

  defp needs_wrap?(_expr, args) when args != [], do: true

  defp needs_wrap?(expression, []) do
    String.contains?(expression, "return ") or
      String.contains?(expression, "return;") or
      String.contains?(expression, "arguments[")
  end

  defp do_eval_expression(%Session{} = session, expression) do
    params = %{
      "expression" => expression,
      "awaitPromise" => false,
      "target" => %{"context" => ctx(session)}
    }

    case Protocol.cdp_send(session, "script.evaluate", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  @doc """
  Evaluate a JS expression and await its returned Promise. Mirrors
  `evaluate/2` for the case where the expression yields a thenable.
  """
  @spec evaluate_async(Session.t(), String.t()) :: {:ok, term} | {:error, term}
  def evaluate_async(%Session{} = session, expression) when is_binary(expression) do
    params = %{
      "expression" => expression,
      "awaitPromise" => true,
      "target" => %{"context" => ctx(session)}
    }

    case Protocol.cdp_send(session, "script.evaluate", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  @doc """
  Run an asynchronous user script — the user's snippet is wrapped so
  the final `arguments[arguments.length - 1]` is a `__resolve`
  callback they invoke with the eventual value. Mirrors
  CDPClient.evaluate_async/3.
  """
  @spec evaluate_async(Session.t(), String.t(), list) :: {:ok, term} | {:error, term}
  def evaluate_async(%Session{} = session, expression, args)
      when is_binary(expression) and is_list(args) do
    args_json = Jason.encode!(args)

    wrapped = """
    new Promise(function(__resolve, __reject) {
      try {
        (function() {
          var __args = #{args_json}.concat([__resolve]);
          (function() { #{expression} }).apply(this, __args);
        })();
      } catch (e) { __reject(e); }
    })
    """

    evaluate_async(session, wrapped)
  end

  defp do_eval_function(%Session{} = session, expression, args) do
    fn_decl = "function() { #{expression} }"

    params = %{
      "functionDeclaration" => fn_decl,
      "arguments" => Enum.map(args, &encode_arg/1),
      "awaitPromise" => false,
      "target" => %{"context" => ctx(session)}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, result} -> decode_eval_result(result)
      error -> error
    end
  end

  @web_element_identifier "element-6066-11e4-a52e-4f735466cecf"

  defp encode_arg(arg) when is_binary(arg), do: %{"type" => "string", "value" => arg}
  defp encode_arg(arg) when is_integer(arg), do: %{"type" => "number", "value" => arg}
  defp encode_arg(arg) when is_float(arg), do: %{"type" => "number", "value" => arg}
  defp encode_arg(true), do: %{"type" => "boolean", "value" => true}
  defp encode_arg(false), do: %{"type" => "boolean", "value" => false}
  defp encode_arg(nil), do: %{"type" => "null"}

  defp encode_arg(arg) when is_list(arg) do
    %{"type" => "array", "value" => Enum.map(arg, &encode_arg/1)}
  end

  # WebDriver-style element reference — translate to a BiDi node handle
  # so `arguments[N]` is a live DOM element on the page side, not an
  # opaque JSON object. Mirrors CDPClient.encode_script_args's
  # element detection.
  defp encode_arg(%{@web_element_identifier => shared_id}) when is_binary(shared_id),
    do: %{"sharedId" => shared_id}

  defp encode_arg(%{"sharedId" => shared_id}) when is_binary(shared_id),
    do: %{"sharedId" => shared_id}

  defp encode_arg(arg) when is_map(arg) do
    pairs =
      Enum.map(arg, fn {k, v} ->
        [encode_arg(to_string(k)), encode_arg(v)]
      end)

    %{"type" => "object", "value" => pairs}
  end

  # BiDi script.evaluate / callFunction returns one of:
  #   %{"type" => "success", "result" => RemoteValue}
  #   %{"type" => "exception", "exceptionDetails" => ...}
  #
  # RemoteValue for primitives is `%{"type" => "string"|"number"|...,
  #   "value" => value}`. For undefined/null it's just `%{"type" =>
  #   "undefined"|"null"}` with no value field. Decode to a plain
  #   Elixir term where possible.
  defp decode_eval_result(%{"type" => "success", "result" => remote}),
    do: {:ok, decode_remote_value(remote)}

  defp decode_eval_result(%{"type" => "exception", "exceptionDetails" => details}),
    do: {:error, {:js_exception, details}}

  defp decode_eval_result(other), do: {:error, {:unexpected_eval_response, other}}

  defp decode_remote_value(%{"type" => "undefined"}), do: nil
  defp decode_remote_value(%{"type" => "null"}), do: nil
  defp decode_remote_value(%{"type" => t, "value" => v}) when t in ["string", "boolean"], do: v
  defp decode_remote_value(%{"type" => "number", "value" => v}) when is_number(v), do: v

  defp decode_remote_value(%{"type" => "number", "value" => "Infinity"}), do: :infinity
  defp decode_remote_value(%{"type" => "number", "value" => "-Infinity"}), do: :neg_infinity
  defp decode_remote_value(%{"type" => "number", "value" => "NaN"}), do: :nan

  defp decode_remote_value(%{"type" => "array", "value" => items}) when is_list(items),
    do: Enum.map(items, &decode_remote_value/1)

  defp decode_remote_value(%{"type" => "object", "value" => pairs}) when is_list(pairs) do
    Enum.into(pairs, %{}, fn [k, v] ->
      {decode_remote_value(k), decode_remote_value(v)}
    end)
  end

  defp decode_remote_value(other), do: other

  # current_url/1, current_path/1, page_title/1, page_source/1 —
  # provided by Wallabidi.Remote.OpsShared.

  # ----- Element-scoped ops -----

  @doc """
  Run a JS function with `this` bound to the given element.
  BiDi's `script.callFunction` accepts a `this` argument — pass it
  the element's sharedId so the function body sees the live DOM
  node. Returns the deserialized value, or `{:error, :stale_reference}`
  for a detached node sentinel.
  """
  @spec call_on_element(Session.t(), Element.t(), String.t(), [term], keyword) ::
          {:ok, term} | {:error, term}
  def call_on_element(session, element, fn_decl, args \\ [], opts \\ [])

  def call_on_element(
        %Session{} = session,
        %Element{handle: {:lazy, query_ops, index, parent_id}},
        fn_decl,
        args,
        opts
      )
      when is_list(query_ops) and is_integer(index) and is_binary(fn_decl) do
    # Lazy element on BiDi: see CDPClient.call_on_element/5 lazy clause.
    [caller_ops] = args
    full_ops = query_ops ++ [["target", index] | caller_ops]
    ops_json = Jason.encode!(full_ops)

    {bidi_method, params} =
      if is_binary(parent_id) do
        {"script.callFunction",
         %{
           "functionDeclaration" => "function() { return window.__w.run(#{ops_json}, this); }",
           "this" => %{"sharedId" => parent_id},
           "arguments" => [],
           "awaitPromise" => Keyword.get(opts, :await_promise, false),
           "target" => %{"context" => ctx(session)}
         }}
      else
        {"script.evaluate",
         %{
           "expression" => "window.__w.run(#{ops_json}, null)",
           "awaitPromise" => Keyword.get(opts, :await_promise, false),
           "target" => %{"context" => ctx(session)}
         }}
      end

    case Protocol.cdp_send(session, bidi_method, params, []) do
      {:ok, %{"type" => "exception", "exceptionDetails" => details}} ->
        if stale_marker?(details),
          do: {:error, :stale_reference},
          else: {:error, {:js_exception, details}}

      {:ok, result} ->
        case decode_eval_result(result) do
          {:ok, %{"error" => "stale_reference"}} ->
            {:error, :stale_reference}

          {:ok, %{"value" => %{"__wallabidi_stale" => true}}} ->
            {:error, :stale_reference}

          {:ok, %{"value" => v}} ->
            {:ok, v}

          {:ok, v} when not is_map(v) ->
            {:ok, v}

          other ->
            other
        end

      error ->
        error
    end
  end

  def call_on_element(
        %Session{} = session,
        %Element{handle: shared_id},
        fn_decl,
        args,
        opts
      )
      when is_binary(shared_id) and is_binary(fn_decl) do
    params = %{
      "functionDeclaration" => fn_decl,
      "this" => %{"sharedId" => shared_id},
      "arguments" => Enum.map(args, &encode_arg/1),
      "awaitPromise" => Keyword.get(opts, :await_promise, false),
      "target" => %{"context" => ctx(session)}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "exception", "exceptionDetails" => details}} ->
        if stale_marker?(details),
          do: {:error, :stale_reference},
          else: {:error, {:js_exception, details}}

      {:ok, result} ->
        case decode_eval_result(result) do
          # call_on_element callers can opt into the stale sentinel by
          # returning `{__wallabidi_stale: true}` — translate it here so
          # they don't all repeat the same pattern.
          {:ok, %{"__wallabidi_stale" => true}} -> {:error, :stale_reference}
          other -> other
        end

      error ->
        error
    end
  end

  defp stale_marker?(%{"text" => msg}) when is_binary(msg) do
    String.contains?(msg, "no such node") or
      String.contains?(msg, "stale element") or
      String.contains?(msg, "detached")
  end

  defp stale_marker?(_), do: false

  # text/2, attribute/3, displayed/2 — provided by Wallabidi.Remote.OpsShared.

  # ----- Element finding -----
  #
  # `find_elements/3` and `find_elements_lazy/3` come from OpsShared.
  # BiDi-specific primitives below are called by OpsShared.do_find_elements
  # via the host-module passthrough.

  @doc false
  def final_sync_exec(%Session{} = session, ops_json, parent_object_id) do
    ctx = ctx(session)
    # Return BOTH elements and the error string. When window.__w is
    # available we use its full opcode interpreter (handles visibility,
    # text filters, etc). When it's not — e.g. about:blank where the
    # preload hasn't run — we fall back to a bare querySelectorAll on
    # just the `query` ops so syntax errors still surface as
    # invalid_selector.
    fallback_body = """
    var r = {els: [], error: null};
    try {
      var ops = #{ops_json};
      for (var i = 0; i < ops.length; i++) {
        var op = ops[i];
        if (op[0] === 'query') {
          r.els = Array.from(document.querySelectorAll(op[2]));
        }
      }
    } catch (e) { r.error = e.message; r.els = []; }
    """

    fn_decl =
      if parent_object_id do
        ~s'function() { if (window.__w) { var r = window.__w.run(#{ops_json}, this); return {els: r.els, error: r.error}; } #{fallback_body} return {els: r.els, error: r.error}; }'
      else
        ~s'() => { if (window.__w) { var r = window.__w.run(#{ops_json}, null); return {els: r.els, error: r.error}; } #{fallback_body} return {els: r.els, error: r.error}; }'
      end

    base_params = %{
      "functionDeclaration" => fn_decl,
      "awaitPromise" => false,
      "resultOwnership" => "root",
      "target" => %{"context" => ctx}
    }

    params =
      if parent_object_id do
        Map.put(base_params, "this", %{"sharedId" => parent_object_id})
      else
        base_params
      end

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "success", "result" => %{"type" => "object", "value" => pairs}}}
      when is_list(pairs) ->
        decode_final_exec(pairs, session)

      _ ->
        {:ok, []}
    end
  end

  defp decode_final_exec(pairs, session) do
    map = pairs_to_map(pairs)

    case Map.get(map, "error") do
      %{"type" => "string", "value" => err} when is_binary(err) and err != "" ->
        {:error, :invalid_selector}

      err when is_binary(err) and err != "" ->
        {:error, :invalid_selector}

      _ ->
        items =
          case Map.get(map, "els") do
            %{"type" => "array", "value" => items} when is_list(items) -> items
            _ -> []
          end

        elements =
          items
          |> Enum.map(fn
            %{"sharedId" => sid} when is_binary(sid) ->
              %Element{
                id: sid,
                handle: sid,
                parent: session,
                driver: session.driver,
                url: session.session_url
              }

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, elements}
    end
  end

  # BiDi `object` RemoteValue serializes as a list of [key, val] pairs.
  # The key is a bare string (not wrapped in a RemoteValue envelope).
  defp pairs_to_map(pairs) do
    Enum.reduce(pairs, %{}, fn
      [k, v], acc when is_binary(k) -> Map.put(acc, k, v)
      [%{"value" => k}, v], acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end

  @doc false
  def cast_register(%Session{} = session, nil, register_js) do
    Protocol.cdp_cast(
      session,
      "script.callFunction",
      %{
        "functionDeclaration" => "() => { #{register_js} }",
        "awaitPromise" => false,
        "target" => %{"context" => ctx(session)}
      },
      []
    )
  end

  def cast_register(%Session{} = session, parent_object_id, register_js)
      when is_binary(parent_object_id) do
    Protocol.cdp_cast(
      session,
      "script.callFunction",
      %{
        "functionDeclaration" => "function() { #{register_js} }",
        "this" => %{"sharedId" => parent_object_id},
        "awaitPromise" => false,
        "target" => %{"context" => ctx(session)}
      },
      []
    )
  end

  @doc false
  # Fetch the resolved query's element list as an array of sharedIds.
  # `resultOwnership: "root"` keeps node references alive on the
  # remote side so we can hold them past this call.
  def fetch_element_refs(%Session{} = session, query_id, found_count) do
    ctx = ctx(session)
    id_js = Jason.encode!(query_id)

    fn_decl = """
    () => {
      var q = window.__w && window.__w.queries && window.__w.queries[#{id_js}];
      return q ? q.elements : [];
    }
    """

    params = %{
      "functionDeclaration" => fn_decl,
      "awaitPromise" => false,
      "resultOwnership" => "root",
      "target" => %{"context" => ctx}
    }

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "success", "result" => %{"type" => "array", "value" => items}}}
      when is_list(items) ->
        elements =
          items
          |> Enum.map(fn
            %{"sharedId" => sid} when is_binary(sid) ->
              %Element{
                id: sid,
                handle: sid,
                parent: session,
                driver: session.driver,
                url: session.session_url
              }

            _ ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        # Best-effort cleanup of the bootstrap's stored entry so memory
        # doesn't accumulate across queries.
        Protocol.cdp_cast(
          session,
          "script.callFunction",
          %{
            "functionDeclaration" => "() => { #{Bootstrap.cleanup_js(query_id)} }",
            "awaitPromise" => false,
            "target" => %{"context" => ctx}
          },
          []
        )

        {:ok, elements}

      _ ->
        # Page navigated mid-flight or the array's gone — emit
        # placeholders so callers see the count, but ops on them will
        # surface as stale_reference.
        {:ok, List.duplicate(%Element{parent: session, driver: session.driver}, found_count)}
    end
  end

  # ----- Interactions -----

  # classify/3 — provided by Wallabidi.Remote.OpsShared.

  @doc """
  LV-aware click. Captures `pre_page_id` BEFORE the click, classifies
  the element to decide what to await, then issues the click and
  blocks for the appropriate signal. Mirrors CDPClient.click_aware
  shape — same primitive contract, BiDi underneath.

  Returns `{:ok, classification}` on success, `{:error, :timeout}`
  if the expected signal didn't arrive, or `{:error, term}` for
  transport errors.
  """
  @spec click_aware(Session.t(), Element.t(), keyword) ::
          {:ok, String.t()} | {:error, term}
  def click_aware(%Session{} = session, %Element{} = element, opts \\ []) do
    case click_aware_with_classification(session, element, opts) do
      {:ok, classification, :ready} -> {:ok, classification}
      {:ok, _classification, :timeout} -> {:error, :timeout}
      err -> err
    end
  end

  @doc """
  Like `click_aware/3` but returns a status tag (`:ready` or
  `:timeout`) so callers can handle patch-classified timeouts
  silently — same shape as CDPClient.click_aware_with_classification.
  """
  @spec click_aware_with_classification(Session.t(), Element.t(), keyword) ::
          {:ok, String.t(), :ready | :timeout} | {:error, term}
  def click_aware_with_classification(%Session{} = session, %Element{} = element, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    pre_click_timeout = Keyword.get(opts, :pre_click_timeout, 200)

    with {:ok, %{"classification" => classification, "prePageId" => pre_page_id}} <-
           await_ready_classify_and_click(session, element, pre_click_timeout) do
      case classification do
        "none" ->
          {:ok, classification, :ready}

        _ ->
          case Protocol.await_page_ready_after(session, pre_page_id, timeout) do
            :ok -> {:ok, classification, :ready}
            :timeout -> {:ok, classification, :timeout}
          end
      end
    end
  end

  defp await_ready_classify_and_click(%Session{} = session, %Element{} = element, timeout_ms) do
    call_on_element(
      session,
      element,
      OpsShared.dispatch_fn(),
      [[["await_ready_classify_and_click", timeout_ms]]],
      await_promise: true
    )
  end

  # click/2 — provided by Wallabidi.Remote.OpsShared.

  @doc """
  DOM-based set_value. Handles checkboxes, radios, options, text
  inputs, AND file inputs.

  File inputs use a DataTransfer + File trick — the browser's
  security model rejects `el.value = "/path"` on file inputs, but
  fabricating an empty File and assigning it via DataTransfer
  populates `el.files` and dispatches the expected `change` event.
  Wallabidi tests only check `.value` (which the browser exposes
  as `C:\\fakepath\\<basename>`), so file content isn't needed.
  """
  @spec set_value(Session.t(), Element.t(), term) :: {:ok, nil} | {:error, term}
  def set_value(%Session{} = session, %Element{} = element, value) do
    case file_input?(session, element) do
      {:ok, true} ->
        # set_file_value uses a custom JS body (DataTransfer), not the
        # W.run dispatcher — so a lazy element can't be passed through.
        # Materialize to a real sharedId first.
        case materialize(session, element) do
          {:ok, eager} -> set_file_input_via_data_transfer(session, eager, to_string(value))
          {:error, _} = err -> err
        end

      _ ->
        set_value_dom(session, element, value)
    end
  end

  # fill_in/4 — provided by Wallabidi.Remote.OpsShared.

  @doc false
  @spec materialize(Session.t(), Element.t()) :: {:ok, Element.t()} | {:error, term}
  def materialize(_session, %Element{handle: id} = element) when is_binary(id),
    do: {:ok, element}

  def materialize(session, %Element{handle: {:lazy, ops, index, parent_id}} = element) do
    ops_json = Jason.encode!(ops)

    fn_decl =
      "function() { var r = window.__w.run(#{ops_json}, this); return r.els[#{index}]; }"

    base_params = %{
      "functionDeclaration" => fn_decl,
      "awaitPromise" => false,
      "resultOwnership" => "root",
      "target" => %{"context" => ctx(session)}
    }

    params =
      if is_binary(parent_id) do
        base_params
        |> Map.put("this", %{"sharedId" => parent_id})
        |> Map.put("arguments", [])
      else
        base_params
        |> Map.put("arguments", [])
      end

    case Protocol.cdp_send(session, "script.callFunction", params, []) do
      {:ok, %{"type" => "success", "result" => %{"sharedId" => sid}}} when is_binary(sid) ->
        {:ok, %{element | handle: sid}}

      _ ->
        {:error, :stale_reference}
    end
  end

  defp file_input?(session, element) do
    call_on_element(session, element, OpsShared.dispatch_fn(), [[["is_file_input"]]])
  end

  # set_value_dom/3 (the DOM-based path) and clear/3 — provided by
  # Wallabidi.Remote.OpsShared. set_value/3 above dispatches between the
  # file-input branch (DataTransfer trick) and the shared DOM path.

  @doc """
  Send text to an element. List form joins; atom form (special keys
  like :tab, :enter) is not supported on the BiDi path yet — would
  require `input.performActions` with a key-source action sequence.
  """
  @spec send_keys(Session.t(), Element.t(), [String.t()] | String.t()) ::
          {:ok, nil} | {:error, term}
  def send_keys(%Session{} = session, %Element{} = element, keys) when is_binary(keys) do
    send_keys(session, element, [keys])
  end

  def send_keys(%Session{} = session, %Element{} = element, keys) when is_list(keys) do
    if Enum.all?(keys, &is_binary/1) do
      send_keys_text(session, element, Enum.join(keys, ""))
    else
      # Mixed string + special-key atoms — focus the element, then
      # dispatch a key-source action sequence via input.performActions.
      with {:ok, _} <-
             call_on_element(session, element, OpsShared.dispatch_fn(), [[["focus"]]]) do
        send_keys_to_session(session, keys)
      end
    end
  end

  @doc """
  Send a key sequence (text + special atoms like :tab, :enter) to
  whatever element currently has focus. BiDi's input.performActions
  with a key-source sequence handles this in one call.
  """
  @spec send_keys_to_session(Session.t(), list) :: {:ok, nil} | {:error, term}
  def send_keys_to_session(%Session{browsing_context: ctx} = session, keys) when is_list(keys) do
    actions = Commands.key_type_actions(keys)
    {method, params} = Commands.perform_actions(ctx, actions)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # ----- Mouse & touch via input.performActions -----

  @doc "Hover the mouse over an element (pointer move to its center)."
  @spec hover(Element.t()) :: {:ok, nil} | {:error, term}
  def hover(%Element{} = element) do
    with {:ok, %Element{handle: sid} = eager} <-
           materialize(Element.root_session(element), element) do
      perform(eager, Commands.pointer_move_actions(sid))
    end
  end

  @doc "Synthesize a tap at the element's center via touch input source."
  @spec tap(Element.t()) :: {:ok, nil} | {:error, term}
  def tap(%Element{} = element) do
    with {:ok, %Element{handle: sid} = eager} <-
           materialize(Element.root_session(element), element) do
      perform(eager, Commands.touch_tap_element_actions(sid))
    end
  end

  @doc """
  Press a touch point. With an element, lands at the element's
  top-left corner plus offsets; without one, lands at the supplied
  absolute coordinates.
  """
  @spec touch_down(Session.t(), Element.t() | nil, number, number) ::
          {:ok, nil} | {:error, term}
  def touch_down(%Session{} = session, nil, x, y) do
    perform(session, Commands.touch_down_actions(round(x), round(y)))
  end

  def touch_down(%Session{} = session, %Element{} = element, x_offset, y_offset) do
    with {:ok, eager} <- materialize(session, element),
         {:ok, {ex, ey}} <- element_location(eager) do
      perform(eager, Commands.touch_down_actions(round(ex + x_offset), round(ey + y_offset)))
    end
  end

  @doc "Release any active touch points."
  @spec touch_up(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  def touch_up(parent), do: perform(parent, Commands.touch_up_actions())

  @doc "Move the active touch point to absolute coordinates."
  @spec touch_move(Session.t() | Element.t(), number, number) :: {:ok, nil} | {:error, term}
  def touch_move(parent, x, y), do: perform(parent, Commands.touch_move_actions(x, y))

  @doc "Press a mouse button at the cursor's current position."
  @spec button_down(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def button_down(parent, button) do
    perform(parent, Commands.pointer_button_down_actions(button))
  end

  @doc "Release a mouse button at the cursor's current position."
  @spec button_up(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def button_up(parent, button) do
    perform(parent, Commands.pointer_button_up_actions(button))
  end

  @doc "Press+release a mouse button at the cursor's current position."
  @spec click_at_cursor(Session.t() | Element.t(), :left | :middle | :right) ::
          {:ok, nil} | {:error, term}
  def click_at_cursor(parent, button) do
    perform(parent, Commands.pointer_click_at_position_actions(button))
  end

  @doc "Move the mouse cursor by an offset from its current position."
  @spec move_mouse_by(Session.t() | Element.t(), number, number) ::
          {:ok, nil} | {:error, term}
  def move_mouse_by(parent, x_offset, y_offset) do
    perform(parent, Commands.pointer_move_by_actions(x_offset, y_offset))
  end

  @doc "Double-click at the cursor's current position."
  @spec double_click(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
  def double_click(parent) do
    perform(parent, Commands.pointer_double_click_actions())
  end

  defp perform(parent, actions) do
    session = Element.root_session(parent)
    {method, params} = Commands.perform_actions(session.browsing_context, actions)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  # element_size/1, element_location/1, selected/2, blank_page?/1 —
  # provided by Wallabidi.Remote.OpsShared.

  # ----- Cookies -----

  @doc """
  Fetch cookies for the session's browsing context. Partitioned by
  context, mirroring the legacy BiDi driver — sessions can't see
  each other's cookies even when sharing the underlying server.
  """
  @spec cookies(Session.t()) :: {:ok, [map]} | {:error, term}
  def cookies(%Session{browsing_context: ctx} = session) do
    {method, params} =
      Commands.get_cookies(%{partition: %{type: "context", context: ctx}})

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, result} -> ResponseParser.extract_cookies(result)
      error -> error
    end
  end

  @doc """
  Set a cookie scoped to the session's browsing context. Accepts
  the standard WebDriver attribute keys (`:domain`, `:path`,
  `:secure`, `:httpOnly`, `:expiry`).
  """
  @spec set_cookie(Session.t(), String.t(), String.t(), map | keyword) ::
          {:ok, nil} | {:error, term}
  def set_cookie(%Session{browsing_context: ctx} = session, name, value, attrs \\ %{})
      when is_binary(name) and is_binary(value) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    cookie =
      %{
        name: name,
        value: %{type: "string", value: value},
        domain: Wallabidi.Remote.Cookies.attr(attrs, :domain, "localhost"),
        path: Wallabidi.Remote.Cookies.attr(attrs, :path, "/")
      }
      |> maybe_put_attr(:secure, attrs)
      |> maybe_put_attr(:httpOnly, attrs)
      |> maybe_put_attr(:expiry, attrs)
      |> maybe_put_same_site(attrs)

    {method, params} =
      Commands.set_cookie(cookie, %{partition: %{type: "context", context: ctx}})

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp maybe_put_attr(cookie, key, attrs) do
    case Wallabidi.Remote.Cookies.attr(attrs, key) do
      nil -> cookie
      v -> Map.put(cookie, key, v)
    end
  end

  defp maybe_put_same_site(cookie, attrs) do
    case Wallabidi.Remote.Cookies.same_site(attrs, :lower) do
      nil -> cookie
      v -> Map.put(cookie, :sameSite, v)
    end
  end

  # ----- Screenshot + viewport -----

  @doc "Capture a PNG screenshot of the current viewport."
  @spec take_screenshot(Session.t()) :: {:ok, binary} | {:error, term}
  def take_screenshot(%Session{browsing_context: ctx} = session) do
    {method, params} = Commands.capture_screenshot(ctx)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, result} -> ResponseParser.extract_screenshot(result)
      error -> error
    end
  end

  @doc "Set the browsing context's viewport size (CSS pixels)."
  @spec set_viewport(Session.t(), non_neg_integer, non_neg_integer) ::
          {:ok, nil} | {:error, term}
  def set_viewport(%Session{browsing_context: ctx} = session, width, height)
      when is_integer(width) and is_integer(height) do
    {method, params} = Commands.set_viewport(ctx, width, height)

    case Protocol.cdp_send(session, method, params, []) do
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  @doc "Read the current viewport size in CSS pixels."
  @spec get_viewport(Session.t()) ::
          {:ok, %{width: non_neg_integer, height: non_neg_integer}} | {:error, term}
  def get_viewport(%Session{} = session) do
    case evaluate(
           session,
           "JSON.stringify({width: window.innerWidth, height: window.innerHeight})"
         ) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"width" => w, "height" => h}} -> {:ok, %{width: w, height: h}}
          _ -> {:error, :bad_size_response}
        end

      error ->
        error
    end
  end

  # ----- Frame focus -----

  @doc """
  Resolve the iframe element to its child browsing-context id.

  Strategy: walk `browsingContext.getTree` rooted at the session's
  current context. Match each child against the iframe's contentWindow
  via a JS test that compares window references. The matching child's
  `context` field is the BiDi browsing-context id we'll switch to.
  """
  @spec child_context_for_iframe(Session.t(), Element.t()) ::
          {:ok, String.t()} | {:error, term}
  def child_context_for_iframe(%Session{browsing_context: parent} = session, %Element{} = element) do
    with {:ok, %{"contexts" => contexts}} <-
           Protocol.cdp_send(
             session,
             "browsingContext.getTree",
             %{"root" => parent, "maxDepth" => 1},
             []
           ),
         children when is_list(children) <- get_children(contexts, parent) do
      find_matching_child(session, element, children)
    else
      _ -> {:error, :no_iframe_context}
    end
  end

  defp get_children([%{"context" => ctx, "children" => children}], ctx) when is_list(children),
    do: children

  defp get_children([%{"children" => children}], _) when is_list(children), do: children

  defp get_children(_, _), do: nil

  defp find_matching_child(_session, _element, []), do: {:error, :no_iframe_context}

  defp find_matching_child(session, %Element{handle: sid} = element, [child | rest]) do
    child_ctx = child["context"]

    # Run a tiny script in the child context that returns its own
    # window. Then run another in the parent context that compares
    # the iframe's contentWindow to the captured ref. If they match,
    # this is the right child.
    case child_url(session, child_ctx) do
      {:ok, child_url} ->
        case iframe_src(session, sid) do
          {:ok, src} when is_binary(src) and src == child_url ->
            {:ok, child_ctx}

          {:ok, src} when is_binary(src) ->
            # URL might differ if iframe loaded a different URL after
            # init. Fall through and try the next child by matching
            # the iframe's contentWindow location against this child's
            # current location.
            if same_origin_match?(src, child_url) do
              {:ok, child_ctx}
            else
              find_matching_child(session, element, rest)
            end

          _ ->
            find_matching_child(session, element, rest)
        end

      _ ->
        find_matching_child(session, element, rest)
    end
  end

  defp child_url(%Session{} = session, child_ctx) do
    params = %{
      "expression" => "location.href",
      "awaitPromise" => false,
      "target" => %{"context" => child_ctx}
    }

    case Protocol.cdp_send(session, "script.evaluate", params, []) do
      {:ok, result} -> decode_eval_result(result)
      err -> err
    end
  end

  defp iframe_src(%Session{} = session, shared_id) do
    parent = %Element{handle: shared_id}

    call_on_element(
      session,
      parent,
      "function() { try { return this.contentWindow.location.href; } catch(e) { return this.src || ''; } }"
    )
  end

  defp same_origin_match?(a, b) when is_binary(a) and is_binary(b) do
    # Loose match: same origin or same path. Tests typically use
    # files-on-test-server, so the URL should match exactly except
    # for trailing slashes / fragments.
    String.starts_with?(a, b) or String.starts_with?(b, a)
  end

  defp same_origin_match?(_, _), do: false

  # ----- Window / tab handles -----

  @doc """
  List all top-level browsing contexts (BiDi's notion of windows /
  tabs). Each returned context id is a "handle" that can be passed
  to V2BiDiDriver.focus_window.
  """
  @spec window_handles(Session.t()) :: {:ok, [String.t()]} | {:error, term}
  def window_handles(%Session{} = session) do
    case Protocol.cdp_send(session, "browsingContext.getTree", %{}, []) do
      {:ok, %{"contexts" => contexts}} when is_list(contexts) ->
        {:ok, Enum.map(contexts, & &1["context"])}

      err ->
        err
    end
  end

  @doc "Close a specific browsing context."
  @spec close_window(Session.t(), String.t()) :: :ok | {:error, term}
  def close_window(%Session{} = session, context_id) when is_binary(context_id) do
    case Protocol.cdp_send(session, "browsingContext.close", %{"context" => context_id}, []) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @doc """
  Walk up the browsing-context tree to the topmost ancestor. Used by
  focus_default_frame to escape out of nested iframes.
  """
  @spec root_context_for(Session.t()) :: {:ok, String.t()} | {:error, term}
  def root_context_for(%Session{browsing_context: ctx} = session) do
    case Protocol.cdp_send(session, "browsingContext.getTree", %{}, []) do
      {:ok, %{"contexts" => contexts}} when is_list(contexts) ->
        # Each top-level entry is a root context. Find the one whose
        # subtree contains our current ctx, then that entry's
        # `context` IS the root.
        case Enum.find(contexts, &subtree_contains?(&1, ctx)) do
          %{"context" => root} -> {:ok, root}
          _ -> {:error, :no_root_context}
        end

      _ ->
        {:error, :no_root_context}
    end
  end

  defp subtree_contains?(%{"context" => c}, target) when c == target, do: true

  defp subtree_contains?(%{"children" => children}, target) when is_list(children) do
    Enum.any?(children, &subtree_contains?(&1, target))
  end

  defp subtree_contains?(_, _), do: false

  # ----- Dialog handling -----
  #
  # Dialog flow lives in Wallabidi.Remote.Dialogs.ChromeBiDi (which uses
  # Wallabidi.Remote.Dialogs.Flow for the protocol-agnostic orchestration).

  @doc """
  Window viewport size. BiDi's native call is `get_viewport/1`;
  exposed here as `get_window_size/1` to match the WireProtocol
  contract used by the Orchestrator.
  """
  @spec get_window_size(Session.t()) :: {:ok, %{width: integer, height: integer}} | {:error, term}
  defdelegate get_window_size(session), to: __MODULE__, as: :get_viewport

  @doc """
  Resize the viewport. Mirrors `set_viewport/3` under the
  WireProtocol-matching name.
  """
  @spec set_window_size(Session.t(), integer, integer) :: {:ok, nil} | {:error, term}
  defdelegate set_window_size(session, width, height), to: __MODULE__, as: :set_viewport
end
