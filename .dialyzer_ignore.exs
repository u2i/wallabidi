# Used for ignoring dialyzer errors
# See: https://github.com/jeremyjh/dialyxir#elixir-term-format
[
  # ExUnit/Mix not available in prod — guarded by try/rescue at runtime
  ~r"Function Mix.env/0 does not exist.",
  ~r"Function ExUnit",

  # GenServer state flow — dialyzer can't track that commands queue before WS
  # handshake, and Mint.WebSocket.new succeeds in practice despite dialyzer's
  # type narrowing from the preceding status/headers handling
  ~r"websocket_client.ex.*(flush_queued_commands|pattern_match)",

  # LiveViewDriver narrows element types to {:lv_element, ...} which is correct
  # but narrower than the Driver behaviour's general Element.t() spec
  ~r"live_view_driver.ex.*callback_arg_type_mismatch",
  ~r"live_view_driver.ex.*callback_type_mismatch",

  # browser.ex: dead catch-all after {:css,_}/{:xpath,_} and Query method
  # narrowing through compile/validate — false positives from flow analysis
  ~r"browser.ex.*pattern_match",

  # Mix.Task behaviour not in PLT — safe to ignore
  ~r"callback_info_missing"
]
