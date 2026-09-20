defmodule Wallabidi.Driver.Utils do
  @moduledoc false

  @type port_number :: 0..65_535

  @spec find_available_port() :: port_number
  def find_available_port do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  @spec merge_args([String.t()], [String.t()], [String.t()]) :: [String.t()]
  def merge_args(args1, args2, []), do: args1 ++ args2

  def merge_args(args1, args2, list_arg_names) do
    (args1 ++ args2)
    |> Enum.reduce([], fn "--" <> arg = original_arg, acc ->
      case Enum.find(list_arg_names, &String.starts_with?(arg, "#{&1}=")) do
        nil ->
          [original_arg | acc]

        key ->
          ^key <> "=" <> value = arg

          case List.keyfind(acc, key, 0) do
            {^key, existing} ->
              List.keyreplace(acc, key, 0, {key, existing <> "," <> value})

            nil ->
              [{key, value} | acc]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {key, value} -> "--#{key}=#{value}"
      arg -> arg
    end)
  end
end
