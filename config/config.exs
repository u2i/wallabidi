import Config

config :wallabidi,
  max_wait_time: 5000,
  pool_size: 3,
  js_logger: :stdio,
  screenshot_on_failure: false,
  js_errors: true

config :lightpanda,
  version: "0.2.8",
  default: [args: ~w(serve --host 127.0.0.1 --port 9222)]

import_config "#{config_env()}.exs"
