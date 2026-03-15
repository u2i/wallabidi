import Config

config :wallabidi,
  tmp_dir_prefix: "wallabidi_test"

if remote_url = System.get_env("WALLABIDI_CHROMEDRIVER_REMOTE_URL") do
  config :wallabidi,
    chromedriver: [
      remote_url: remote_url
    ]
end
