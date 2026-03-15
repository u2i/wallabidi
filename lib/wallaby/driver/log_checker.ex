defmodule Wallaby.Driver.LogChecker do
  @moduledoc false
  alias Wallaby.Driver.LogStore

  def check_logs!(%{driver: driver} = session, fun) do
    return_value = fun.()

    if bidi_session?(session) do
      # With BiDi, logs will be collected via event subscription in the future.
      # For now, still poll via HTTP as a fallback.
      try do
        {:ok, logs} = driver.log(session)

        session.session_url
        |> LogStore.append_logs(logs)
        |> Enum.each(&driver.parse_log/1)
      rescue
        _ -> :ok
      end
    else
      {:ok, logs} = driver.log(session)

      session.session_url
      |> LogStore.append_logs(logs)
      |> Enum.each(&driver.parse_log/1)
    end

    return_value
  end

  defp bidi_session?(%Wallaby.Session{bidi_pid: pid}) when is_pid(pid), do: true
  defp bidi_session?(%Wallaby.Element{parent: parent}), do: bidi_session?(parent)
  defp bidi_session?(_), do: false
end
