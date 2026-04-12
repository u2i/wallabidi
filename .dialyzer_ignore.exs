# Used for ignoring dialyzer errors
# See: https://github.com/jeremyjh/dialyxir#elixir-term-format
[
  # ExUnit/Mix not available in prod — guarded by try/rescue at runtime
  ~r"Function Mix.env/0 does not exist.",
  ~r"Function ExUnit",

  # GenServer state flow — dialyzer can't track that commands queue before WS
  # handshake, and Mint.WebSocket.new succeeds in practice despite dialyzer's
  # type narrowing from the preceding status/headers handling
  ~r"websocket_client.ex.*(flush_queued_commands|pattern_match|can never match)",
  # Same warning in Erlang type format on Elixir 1.19
  ~r"ok.*_conn.*_websocket.*can never match",

  # LiveViewDriver narrows element types to {:lv_element, ...} which is correct
  # but narrower than the Driver behaviour's general Element.t() spec
  ~r"live_view_driver.ex.*callback_arg_type_mismatch",
  ~r"live_view_driver.ex.*callback_type_mismatch",

  # browser.ex: Query method narrowing through compile/validate — false positive
  ~r"browser.ex.*(pattern_match|can never match)",
  # Same warning in Erlang type format on Elixir 1.19
  ~r"method.*text.*can never match",

  # Mix.Task behaviour and Mix.shell/Mix.raise not in PLT
  ~r"callback_info_missing",
  ~r"Function Mix\.(shell|raise|env)",

  # Protocol.subscribe called during session init before SessionProcess
  # sets pid — dialyzer narrows the session struct type
  ~r"chrome\.ex:\d+:\d+:call",
  ~r"chrome_cdp\.ex:\d+:\d+:call",

  # await_patch CAN return :timeout ({:ok, false} path) but dialyzer
  # narrows the eval_async return type and thinks it's unreachable
  ~r"cdp_client\.ex.*1051.*pattern_match",

  # first_attr returns string|nil but dialyzer narrows to string in some paths
  ~r"(live_view_driver|native).ex.*(guard_fail|can never succeed)"
]
