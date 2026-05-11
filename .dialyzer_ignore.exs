# Dialyzer ignore patterns — each matches a real warning from `mix dialyzer`
# See: https://github.com/jeremyjh/dialyxir#elixir-term-format
[
  # event_emitter.ex: ExUnit not available outside test
  ~r"event_emitter.ex.*unknown_function",

  # Mix.Task behaviour not in PLT
  ~r"callback_info_missing",

  # Mix.shell/Mix.raise not in PLT (mix task helpers)
  ~r"Function Mix\.(shell|raise)",

  # GenServer state flow — dialyzer can't track that commands queue before
  # WS handshake completes. Hits both legacy websocket_client and the new
  # Wallabidi.Remote.WebSocket / per_session/actor paths.
  ~r"websocket_client.ex.*pattern_match",
  ~r"websocket_client.ex.*unused_fun",
  ~r"remote/websocket\.ex.*pattern_match",
  ~r"remote/websocket\.ex.*unused_fun",
  ~r"remote/transport/per_session/actor\.ex.*pattern_match",
  ~r"remote/transport/per_session/actor\.ex.*unused_fun",

  # browser.ex: Query method narrowing through compile/validate
  ~r"browser.ex.*pattern_match",

  # CDP: await_patch returns :timeout via {:ok, false} path but dialyzer
  # narrows eval_async return type
  ~r"cdp_client.ex.*1051.*pattern_match",
  ~r"remote/cdp/client\.ex.*pattern_match",

  # Protocol.subscribe called during session init before pid is set
  ~r"chrome\.ex:\d+:\d+:call",
  ~r"chrome_cdp\.ex:\d+:\d+:call",
  ~r"remote/drivers/chrome_cdp\.ex:\d+:\d+:call",

  # LV-driver narrows Element handle to {:lv_element, ...} — broader
  # Element.t() type intentionally accepts this plus driver-specific shapes.
  ~r"live_view_driver.ex.*callback_arg_type_mismatch",
  ~r"live_view_driver.ex.*callback_type_mismatch",
  ~r"live_view_driver.ex.*guard_fail",
  ~r"live_view/driver\.ex.*callback_arg_type_mismatch",
  ~r"live_view/driver\.ex.*callback_type_mismatch",
  ~r"live_view/driver\.ex.*guard_fail",

  # native.ex / live_view/driver.ex: first_attr returns string|nil, dialyzer
  # narrows to string after one branch
  ~r"native.ex.*guard_fail",

  # BiDi iframe-focus helpers: chromium-bidi getTree returns a deeply nested
  # type that dialyzer can't fully unwrap; the find_matching_child path's
  # error-only success type is structural, not a real bug.
  ~r"remote/bidi/client\.ex.*no_return",
  ~r"remote/bidi/client\.ex.*call",
  ~r"remote/bidi/client\.ex.*unused_fun",
  ~r"remote/drivers/chrome_bidi\.ex.*pattern_match",
  ~r"remote/drivers/chrome_bidi\.ex.*unused_fun",
  ~r"chrome_bidi\.ex:\d+: The test binary\(\) =:= 'nil'"
]
