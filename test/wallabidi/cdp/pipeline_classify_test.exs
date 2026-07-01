defmodule Wallabidi.Remote.CDP.PipelineClassifyTest do
  use ExUnit.Case, async: true

  # Tests `W.classify` from priv/wallabidi.js — the production classifier
  # called by every CDP/BiDi click pipeline. Runs in node against stubbed
  # DOM elements so each branch is exercised in isolation.
  #
  # Earlier versions of this test extracted classify_fn from
  # Wallabidi.Remote.CDP.Pipeline (now deleted). priv/wallabidi.js is the
  # single source of truth.

  @moduletag :classifier

  @bundle_path Path.expand("../../../priv/wallabidi.js", __DIR__)

  setup_all do
    case System.find_executable("node") do
      nil -> {:ok, skip: true}
      _ -> {:ok, skip: false}
    end
  end

  # Pull the `W.classify = function(el, type) { ... };` definition from
  # priv/wallabidi.js. Returns the function expression as a standalone
  # callable for the test harness.
  defp classify_js do
    src = File.read!(@bundle_path)

    # `W.classify = function(el, type) { ... };` — match up to the
    # closing `};` at column 0 (the function body's outer brace).
    [_, fn_src] = Regex.run(~r/W\.classify = (function\(el, type\) \{.*?\n\});/s, src)
    fn_src
  end

  defp run_classify(dom_setup_js, el_expr, type) do
    classifier = classify_js()

    script = """
    var classify = #{classifier};

    // Minimal Element/HTMLFormElement stub factory.
    function makeEl(props) {
      var attrs = props.attrs || {};
      return {
        tagName: (props.tagName || 'DIV').toUpperCase(),
        type: props.type,
        _attrs: attrs,
        _parent: props.parent,
        _form: props.form,
        _anchor: props.anchor,
        _dataPhxLink: props.dataPhxLink,
        getAttribute: function(k) {
          return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null;
        },
        hasAttribute: function(k) {
          return Object.prototype.hasOwnProperty.call(this._attrs, k);
        },
        closest: function(sel) {
          if (sel === 'form') return this._form || null;
          if (sel === '[data-phx-link]') return this._dataPhxLink || null;
          if (sel === 'a[href]') return this._anchor || null;
          return null;
        }
      };
    }

    #{dom_setup_js}

    var result = classify(#{el_expr}, #{Jason.encode!(to_string(type))});
    process.stdout.write(result);
    """

    path =
      Path.join(System.tmp_dir!(), "wallabidi_classify_#{System.unique_integer([:positive])}.js")

    File.write!(path, script)

    try do
      {out, 0} = System.cmd("node", [path])
      out
    after
      File.rm(path)
    end
  end

  describe "click classification — phx-trigger-action" do
    @tag :classifier
    test "button in form with phx-trigger-action classifies as full_page" do
      # AshAuthentication pattern: phx-submit wires up LiveView validation,
      # phx-trigger-action flips truthy on success and triggers a native form
      # submit to `action=`. The full-page submit is the load-bearing event, so
      # the classifier must wait for a full page load, not a LiveView patch.
      setup_js = """
      var form = makeEl({
        tagName: 'FORM',
        attrs: {'phx-submit': 'submit', 'phx-trigger-action': 'true', 'action': '/sign_in'}
      });
      var btn = makeEl({tagName: 'BUTTON', type: 'submit', form: form});
      """

      assert run_classify(setup_js, "btn", :click) == "full_page"
    end

    @tag :classifier
    test "button in form with phx-submit only classifies as patch" do
      # Plain LiveView form — no trigger-action, so it's a pure LV event.
      setup_js = """
      var form = makeEl({tagName: 'FORM', attrs: {'phx-submit': 'save'}});
      var btn = makeEl({tagName: 'BUTTON', type: 'submit', form: form});
      """

      assert run_classify(setup_js, "btn", :click) == "patch"
    end
  end

  describe "click classification — anchors and data-phx-link" do
    @tag :classifier
    test "anchor with data-phx-link=redirect classifies as navigate" do
      setup_js = """
      var link = makeEl({tagName: 'A', attrs: {'data-phx-link': 'redirect'}});
      var el = makeEl({tagName: 'SPAN', dataPhxLink: link});
      """

      assert run_classify(setup_js, "el", :click) == "navigate"
    end

    @tag :classifier
    test "anchor with data-phx-link=patch classifies as patch" do
      setup_js = """
      var link = makeEl({tagName: 'A', attrs: {'data-phx-link': 'patch'}});
      var el = makeEl({tagName: 'SPAN', dataPhxLink: link});
      """

      assert run_classify(setup_js, "el", :click) == "patch"
    end

    @tag :classifier
    test "plain anchor with absolute href classifies as full_page" do
      setup_js = """
      var a = makeEl({tagName: 'A', attrs: {'href': '/x'}});
      var el = makeEl({tagName: 'SPAN', anchor: a});
      """

      assert run_classify(setup_js, "el", :click) == "full_page"
    end

    @tag :classifier
    test "anchor with fragment-only href classifies as none" do
      # Fragment links don't navigate the page — no await needed.
      setup_js = """
      var a = makeEl({tagName: 'A', attrs: {'href': '#section'}});
      var el = makeEl({tagName: 'SPAN', anchor: a});
      """

      assert run_classify(setup_js, "el", :click) == "none"
    end
  end

  describe "click classification — forms without phx-submit" do
    @tag :classifier
    test "button in plain form with action classifies as full_page" do
      setup_js = """
      var form = makeEl({tagName: 'FORM', attrs: {'action': '/submit'}});
      var btn = makeEl({tagName: 'BUTTON', type: 'submit', form: form});
      """

      assert run_classify(setup_js, "btn", :click) == "full_page"
    end

    @tag :classifier
    test "button outside any form and without phx-click classifies as none" do
      setup_js = """
      var btn = makeEl({tagName: 'BUTTON'});
      """

      assert run_classify(setup_js, "btn", :click) == "none"
    end
  end

  describe "click classification — phx-click JS commands" do
    @tag :classifier
    test "phx-click with JS.navigate classifies as navigate" do
      # JS.navigate(~p"/student") renders as a JSON-encoded command list:
      # [["navigate",{"href":"/student","replace":false}]]
      phx = ~s([["navigate",{"href":"/student","replace":false}]])

      setup_js = """
      var btn = makeEl({tagName: 'BUTTON', attrs: {'phx-click': #{Jason.encode!(phx)}}});
      """

      assert run_classify(setup_js, "btn", :click) == "navigate"
    end

    @tag :classifier
    test "phx-click with JS.patch classifies as patch" do
      phx = ~s([["patch",{"href":"/other","replace":false}]])

      setup_js = """
      var btn = makeEl({tagName: 'BUTTON', attrs: {'phx-click': #{Jason.encode!(phx)}}});
      """

      assert run_classify(setup_js, "btn", :click) == "patch"
    end

    @tag :classifier
    test "phx-click with JS.push classifies as patch" do
      phx = ~s([["push",{"event":"save"}]])

      setup_js = """
      var btn = makeEl({tagName: 'BUTTON', attrs: {'phx-click': #{Jason.encode!(phx)}}});
      """

      assert run_classify(setup_js, "btn", :click) == "patch"
    end

    @tag :classifier
    test "phx-click with plain event name classifies as patch" do
      setup_js = """
      var btn = makeEl({tagName: 'BUTTON', attrs: {'phx-click': 'save'}});
      """

      assert run_classify(setup_js, "btn", :click) == "patch"
    end

    @tag :classifier
    test "phx-click with no recognised JS commands classifies as none" do
      # Fire-and-forget JS commands like JS.dispatch, JS.toggle — no navigation,
      # no server round-trip, so no await needed.
      phx = ~s([["dispatch",{"event":"custom"}]])

      setup_js = """
      var btn = makeEl({tagName: 'BUTTON', attrs: {'phx-click': #{Jason.encode!(phx)}}});
      """

      assert run_classify(setup_js, "btn", :click) == "none"
    end
  end
end
