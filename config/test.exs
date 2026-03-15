import Config

config :wallaby,
  tmp_dir_prefix: "wallaby_test"

if remote_url = System.get_env("WALLABY_CHROMEDRIVER_REMOTE_URL") do
  config :wallaby,
    chromedriver: [
      remote_url: remote_url
    ]
end
