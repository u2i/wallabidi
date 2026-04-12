# Dialyzer ignore patterns — each matches a real warning from `mix dialyzer`
# See: https://github.com/jeremyjh/dialyxir#elixir-term-format
[
  # event_emitter.ex: ExUnit not available outside test
  ~r"event_emitter.ex.*unknown_function",

  # Mix.Task behaviour not in PLT
  ~r"callback_info_missing",

  # Mix.shell/Mix.raise not in PLT (mix task helpers)
  ~r"Function Mix\.(shell|raise)",

  # GenServer state flow — dialyzer can't track that commands queue before WS
  # handshake completes
  ~r"websocket_client.ex.*pattern_match",
  ~r"websocket_client.ex.*unused_fun",

  # browser.ex: Query method narrowing through compile/validate
  ~r"browser.ex.*pattern_match",

  # CDP: await_patch returns :timeout via {:ok, false} path but dialyzer
  # narrows eval_async return type
  ~r"cdp_client.ex.*1051.*pattern_match",

  # Protocol.subscribe called during session init before pid is set
  ~r"chrome\.ex:\d+:\d+:call",
  ~r"chrome_cdp\.ex:\d+:\d+:call",

  # LiveViewDriver narrows element types to {:lv_element, ...}
  ~r"live_view_driver.ex.*callback_arg_type_mismatch",
  ~r"live_view_driver.ex.*callback_type_mismatch",
  ~r"live_view_driver.ex.*guard_fail",

  # native.ex: first_attr returns string|nil, dialyzer narrows to string
  ~r"native.ex.*guard_fail"
]
