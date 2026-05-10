defmodule Wallabidi.Remote.CDP.Ops do
  @moduledoc false

  # Builds a list of opcodes for the browser-side interpreter.
  # No JS generation — just data that gets JSON-serialized into the
  # register call. The interpreter lives in the bootstrap script
  # installed via Page.addScriptToEvaluateOnNewDocument.
  #
  # ## Opcodes (the W.run vocabulary — see priv/wallabidi.js)
  #
  #   ["query", "css"|"xpath", selector]
  #   ["visible", true|false]
  #   ["text_includes", string]
  #   ["selected", true|false]
  #   ["classify_first", "click"|"change"|"submit"]
  #   ["prepare_patch_filter"]
  #   ["click_first"]
  #
  # The pipeline-state ops (classify_first / click_first / *_filter)
  # are named distinctly from the per-element ops in W.run because the
  # interpreter needs to disambiguate "classify a single target" from
  # "classify els[0] and stash on meta".
  #
  # ## Example
  #
  #   Ops.new()
  #   |> Ops.query(:css, ".btn")
  #   |> Ops.visible(true)
  #   |> Ops.click()
  #   |> Ops.to_query(count: 1, timeout: 5000)
  #   #=> %{ops: [["query","css",".btn"],["visible",true],["click_first"]], count: 1, timeout: 5000}

  defstruct ops: [], parent_id: nil

  def new, do: %__MODULE__{}

  def new(%{bidi_shared_id: parent_id}) when not is_nil(parent_id) do
    %__MODULE__{parent_id: parent_id}
  end

  def new(_), do: %__MODULE__{}

  def query(%__MODULE__{} = o, type, selector) do
    %{o | ops: o.ops ++ [["query", to_string(type), selector]]}
  end

  def visible(%__MODULE__{} = o, val) when is_boolean(val) do
    %{o | ops: o.ops ++ [["visible", val]]}
  end

  def text(%__MODULE__{} = o, text) when is_binary(text) do
    %{o | ops: o.ops ++ [["text_includes", text]]}
  end

  def selected(%__MODULE__{} = o, val) when is_boolean(val) do
    %{o | ops: o.ops ++ [["selected", val]]}
  end

  def classify(%__MODULE__{} = o, interaction) do
    %{o | ops: o.ops ++ [["classify_first", to_string(interaction)]]}
  end

  def prepare_patch(%__MODULE__{} = o) do
    %{o | ops: o.ops ++ [["prepare_patch_filter"]]}
  end

  def click(%__MODULE__{} = o) do
    %{o | ops: o.ops ++ [["click_first"]]}
  end

  @doc """
  Returns `true` if any op has side effects (click, prepare_patch).
  Side-effect ops mean the result must be captured before the side
  effect fires (to avoid stale context on navigation).
  """
  def has_side_effects?(%__MODULE__{ops: ops}) do
    Enum.any?(ops, fn
      ["click_first"] -> true
      ["prepare_patch_filter"] -> true
      _ -> false
    end)
  end

  @doc """
  Build filters from a Wallaby Query struct.
  """
  def from_query(%__MODULE__{} = o, query) do
    o =
      case Wallabidi.Query.visible?(query) do
        true -> visible(o, true)
        false -> visible(o, false)
        _ -> o
      end

    o =
      case Wallabidi.Query.inner_text(query) do
        nil -> o
        t -> text(o, t)
      end

    case Wallabidi.Query.selected?(query) do
      true -> selected(o, true)
      false -> selected(o, false)
      _ -> o
    end
  end

  @doc """
  Build a complete opcode sequence directly from a Wallaby Query + action.
  Validates and compiles the query, applies all filters, and appends
  action ops (classify, prepare_patch, click) based on the action type.

  Actions:
  - `nil`    — find only (for assert_has, find, has?)
  - `:click` — classify + prepare_patch + click

  Returns `{:ok, ops, query}` or `{:error, reason}`.
  """
  def from_wallaby(parent, %Wallabidi.Query{} = query, action \\ nil) do
    with {:ok, validated} <- Wallabidi.Query.validate(query) do
      {type, selector} = Wallabidi.Query.compile(validated)

      ops =
        new(parent)
        |> query(type, selector)
        |> from_query(validated)

      ops =
        case action do
          :click ->
            ops
            |> classify(:click)
            |> prepare_patch()
            |> click()

          _ ->
            ops
        end

      {:ok, ops, validated}
    end
  end
end
