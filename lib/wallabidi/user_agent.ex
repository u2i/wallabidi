defmodule Wallabidi.UserAgent do
  @moduledoc false

  # Resolves the User-Agent a session should report, from (highest priority
  # first):
  #
  #   1. the `:user_agent` option passed to `Wallabidi.start_session/1`
  #   2. `config :wallabidi, user_agent: "..."`
  #   3. the driver's own default
  #
  # The two levels exist because the drivers differ in what they can do.
  # Chrome sets the UA per CDP/BiDi session, so it can honour either.
  # Lightpanda sets it per *process* (a `--user-agent` CLI flag on the
  # shared binary), so it can only honour the config level — every session
  # on that binary shares one UA. `Wallabidi.start_session(user_agent:)`
  # therefore warns on Lightpanda rather than silently doing nothing.

  @config_key :user_agent

  @doc """
  The configured User-Agent, or `nil` when none is set.
  """
  @spec configured() :: String.t() | nil
  def configured, do: Application.get_env(:wallabidi, @config_key)

  @doc """
  Resolve the base User-Agent for a session: the `:user_agent` option if
  given, else the configured one, else `default`.
  """
  @spec resolve(keyword, String.t()) :: String.t()
  def resolve(opts, default) do
    Keyword.get(opts, @config_key) || configured() || default
  end

  @doc """
  Whether a session needs an explicit override sent — true when the caller
  or the config asked for a specific UA, or when sandbox metadata has to be
  appended to whatever the UA is.
  """
  @spec override?(keyword) :: boolean
  def override?(opts) do
    Keyword.has_key?(opts, @config_key) or
      configured() != nil or
      Keyword.get(opts, :metadata) != nil
  end
end
