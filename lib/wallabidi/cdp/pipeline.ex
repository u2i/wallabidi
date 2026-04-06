defmodule Wallabidi.CDP.Pipeline do
  @moduledoc false

  # Builds a find + filter chain as data, compiles to one JS function that
  # returns a flat array of DOM nodes. One `evaluate` + one `getProperties`
  # replaces the old `evaluate → getProperties → [callFunctionOn × N]`
  # chain (2 RPCs instead of 2+N).
  #
  # ## Example
  #
  #     Pipeline.new()
  #     |> Pipeline.query_all(:css, "#menu-btn")
  #     |> Pipeline.filter_visible()
  #     |> Pipeline.filter_text("Menu")
  #     |> Pipeline.to_js()
  #     #=> "(() => { var els; els = ...; els = els.filter(...); return els; })()"
  #
  # The returned JS always evaluates to an array of DOM nodes (live
  # references). Callers use the existing `find_elements_js` / `find_elements_on`
  # machinery to extract objectIds via `getProperties`.

  defstruct ops: [], parent_id: nil

  def new, do: %__MODULE__{}

  def new(%{bidi_shared_id: parent_id}) when not is_nil(parent_id) do
    %__MODULE__{parent_id: parent_id}
  end

  def new(_), do: %__MODULE__{}

  def query_all(%__MODULE__{} = p, :css, selector) do
    %{p | ops: p.ops ++ [{:query_css, selector}]}
  end

  def query_all(%__MODULE__{} = p, :xpath, xpath) do
    %{p | ops: p.ops ++ [{:query_xpath, xpath}]}
  end

  def filter_visible(%__MODULE__{} = p) do
    %{p | ops: p.ops ++ [:filter_visible]}
  end

  def filter_not_visible(%__MODULE__{} = p) do
    %{p | ops: p.ops ++ [:filter_not_visible]}
  end

  def filter_text(%__MODULE__{} = p, text) do
    %{p | ops: p.ops ++ [{:filter_text, text}]}
  end

  def filter_selected(%__MODULE__{} = p, selected) do
    %{p | ops: p.ops ++ [{:filter_selected, selected}]}
  end

  @doc """
  Append classification metadata to the result array. The classification
  string is set as `els.__classify` so `getProperties` returns it alongside
  the element objectIds. The caller can extract it without an extra RPC.
  """
  def classify(%__MODULE__{} = p, interaction) do
    %{p | ops: p.ops ++ [{:classify, interaction}]}
  end

  @doc """
  Compiles the pipeline to a JS expression string. Returns `{js, parent_id}`
  where `parent_id` is nil for document-level queries or an objectId for
  element-scoped queries (to be executed via `callFunctionOn`).
  """
  def to_js(%__MODULE__{ops: ops, parent_id: parent_id}) do
    root = if parent_id, do: "this", else: "document"

    body =
      ops
      |> Enum.map(fn op -> compile_op(op, root) end)
      |> Enum.join("\n")

    js =
      if parent_id do
        """
        function() {
          var els;
          #{body}
          return els;
        }
        """
      else
        """
        (() => {
          var els;
          #{body}
          return els;
        })()
        """
      end

    {js, parent_id}
  end

  # --- Op compilation ---

  defp compile_op({:query_css, selector}, root) do
    "els = Array.from(#{root}.querySelectorAll(#{Jason.encode!(selector)}));"
  end

  defp compile_op({:query_xpath, xpath}, root) do
    # Use a block scope instead of an IIFE to preserve `this` binding
    # from callFunctionOn. An IIFE rebinds `this` to undefined/window.
    """
    try {
      var _xctx = #{root};
      if (!_xctx || !_xctx.nodeType) _xctx = document;
      var _xr = document.evaluate(#{Jason.encode!(xpath)}, _xctx, null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      els = [];
      for (var _xi = 0; _xi < _xr.snapshotLength; _xi++) els.push(_xr.snapshotItem(_xi));
    } catch(_xe) { els = []; }
    """
  end

  defp compile_op(:filter_visible, _root) do
    "els = els.filter(#{visibility_fn()});"
  end

  defp compile_op(:filter_not_visible, _root) do
    "els = els.filter(function(el) { return !(#{visibility_fn()})(el); });"
  end

  defp compile_op({:filter_text, text}, _root) do
    """
    els = els.filter(function(el) {
      var t = (el.innerText || el.textContent || '').replace(/[\\s\\u00a0]+/g, ' ').trim();
      return t.indexOf(#{Jason.encode!(text)}) !== -1;
    });
    """
  end

  defp compile_op({:filter_selected, true}, _root) do
    "els = els.filter(function(el) { return el.selected || el.checked || false; });"
  end

  defp compile_op({:filter_selected, false}, _root) do
    "els = els.filter(function(el) { return !(el.selected || el.checked); });"
  end

  defp compile_op({:classify, interaction}, _root) do
    """
    if (els.length > 0) {
      els.__classify = (#{classify_fn()})(els[0], #{Jason.encode!(to_string(interaction))});
    } else {
      els.__classify = "none";
    }
    """
  end

  # Inline visibility function — same logic as CDPClient.displayed/1
  defp visibility_fn do
    """
    function(el) {
      if (!el.isConnected) return false;
      if (el.tagName === 'OPTION') {
        var select = el.closest('select');
        if (!select) return true;
        var ss = window.getComputedStyle(select);
        return ss.display !== 'none' && ss.visibility !== 'hidden';
      }
      var style = window.getComputedStyle(el);
      if (style.display === 'none') return false;
      if (style.visibility === 'hidden') return false;
      var rect = el.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0 && el.offsetParent === null && style.position !== 'fixed') return false;
      if (rect.bottom < 0) return false;
      if (rect.right < 0) return false;
      return true;
    }
    """
  end

  defp classify_fn do
    """
    function(el, type) {
      if (!el) return "none";
      if (type === 'click') {
        var link = el.closest('[data-phx-link]');
        if (link) return link.getAttribute('data-phx-link') === 'redirect' ? 'navigate' : 'patch';
        var phxClick = el.getAttribute('phx-click');
        if (phxClick) return (phxClick.includes('push') || !phxClick.startsWith('[')) ? 'patch' : 'none';
        if (el.type === 'submit' || el.tagName === 'BUTTON') {
          var form = el.closest('form');
          if (form && form.getAttribute('phx-submit')) return 'patch';
          if (form) return 'full_page';
        }
        var anchor = el.closest('a[href]');
        if (anchor && anchor.getAttribute('href') && !anchor.getAttribute('href').startsWith('#')) return 'full_page';
        return 'none';
      }
      if (type === 'change') {
        var phxChange = el.getAttribute('phx-change') || (el.form && el.form.getAttribute('phx-change'));
        return phxChange ? 'patch' : 'none';
      }
      if (type === 'submit') {
        var f = el.closest('form');
        if (f && f.getAttribute('phx-submit')) return 'patch';
        if (f) return 'full_page';
        return 'none';
      }
      return 'none';
    }
    """
  end
end
