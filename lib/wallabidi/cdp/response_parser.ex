defmodule Wallabidi.CDP.ResponseParser do
  @moduledoc false

  def check_error({:ok, result}), do: {:ok, result}
  def check_error({:error, _} = error), do: error

  # Extract a plain value from Runtime.evaluate with returnByValue: true
  def extract_value({:ok, %{"result" => %{"type" => "undefined"}}}), do: {:ok, nil}

  def extract_value({:ok, %{"result" => %{"value" => value}}}), do: {:ok, value}

  def extract_value({:ok, %{"result" => %{"type" => "object", "subtype" => "null"}}}),
    do: {:ok, nil}

  def extract_value({:ok, %{"result" => %{"unserializableValue" => val}}}), do: {:ok, val}

  # Exception during evaluation
  def extract_value({:ok, %{"exceptionDetails" => %{"exception" => %{"description" => desc}}}}),
    do: {:error, {:js_error, desc}}

  def extract_value({:ok, %{"exceptionDetails" => details}}),
    do: {:error, {:js_error, inspect(details)}}

  def extract_value({:ok, other}), do: {:ok, other}
  def extract_value(error), do: error

  # Extract objectId from Runtime.evaluate with returnByValue: false
  def extract_object_id({:ok, %{"result" => %{"objectId" => object_id}}}),
    do: {:ok, object_id}

  def extract_object_id({:ok, %{"result" => %{"type" => "undefined"}}}),
    do: {:ok, nil}

  def extract_object_id({:ok, %{"result" => %{"type" => "object", "subtype" => "null"}}}),
    do: {:ok, nil}

  def extract_object_id(
        {:ok, %{"exceptionDetails" => %{"exception" => %{"description" => desc}}}}
      ),
      do: {:error, {:js_error, desc}}

  def extract_object_id(other), do: other

  # Extract element objectIds from Runtime.getProperties result
  # Used after querySelectorAll returns an array-like object
  def extract_element_ids({:ok, %{"result" => properties}}) when is_list(properties) do
    ids =
      properties
      |> Enum.filter(fn prop ->
        is_integer_key?(prop["name"]) and
          get_in(prop, ["value", "type"]) == "object" and
          get_in(prop, ["value", "subtype"]) == "node"
      end)
      |> Enum.sort_by(fn prop -> String.to_integer(prop["name"]) end)
      |> Enum.map(fn prop -> get_in(prop, ["value", "objectId"]) end)
      |> Enum.reject(&is_nil/1)

    {:ok, ids}
  end

  def extract_element_ids({:ok, _}), do: {:ok, []}
  def extract_element_ids(error), do: error

  # Check if a navigate response has an error
  def check_navigate({:ok, %{"errorText" => error}}), do: {:error, error}
  def check_navigate({:ok, _}), do: :ok
  def check_navigate(error), do: error

  defp is_integer_key?(name) when is_binary(name) do
    case Integer.parse(name) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp is_integer_key?(_), do: false
end
