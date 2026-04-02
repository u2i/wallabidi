defmodule Wallabidi.Chrome.Chromedriver.ReadinessChecker do
  @moduledoc false

  @type url :: String.t()

  @spec wait_until_ready(url, non_neg_integer()) :: :ok
  def wait_until_ready(base_url, delay \\ 200)
      when is_binary(base_url) and is_integer(delay) and delay >= 0 do
    if ready?(base_url) do
      :ok
    else
      Process.sleep(delay)
      wait_until_ready(base_url, delay)
    end
  end

  defp ready?(base_url) do
    uri = URI.parse("#{base_url}status")
    port = uri.port || 80

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, port),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", uri.path, [], ""),
         {:ok, body} <- receive_body(conn, ref) do
      case Jason.decode(body) do
        {:ok, %{"value" => %{"ready" => true}}} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp receive_body(conn, ref, acc \\ "") do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {done?, acc} =
              Enum.reduce(responses, {false, acc}, fn
                {:data, ^ref, data}, {_, a} -> {false, a <> data}
                {:done, ^ref}, {_, a} -> {true, a}
                _, acc -> acc
              end)

            if done? do
              Mint.HTTP.close(conn)
              {:ok, acc}
            else
              receive_body(conn, ref, acc)
            end

          _ ->
            {:error, :stream_error}
        end
    after
      2_000 -> {:error, :timeout}
    end
  end
end
