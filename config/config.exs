import Config

config :wallabidi,
  max_wait_time: 5000,
  pool_size: 3,
  js_logger: :stdio,
  screenshot_on_failure: false,
  js_errors: true

import_config "#{config_env()}.exs"
