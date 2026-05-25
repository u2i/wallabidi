defmodule Wallabidi.Integration.LiveApp.PlainFormController do
  use Phoenix.Controller, formats: [:html]

  @doc """
  Vanilla (non-LiveView) page that installs four click listeners and
  records how many times each one was invoked. Used by the driver-
  parity event-propagation tests to isolate which DOM event-flow
  guarantees a given driver upholds.

  Listeners:

    * `#root-capture`      — addEventListener on the ancestor div,  capture phase
    * `#root-bubble`       — addEventListener on the ancestor div,  bubble phase
    * `#document-capture`  — addEventListener on document,          capture phase
    * `#document-bubble`   — addEventListener on document,          bubble phase

  Each listener increments its own counter span. The test reads
  `textContent` after each click to determine which phases fired.

  Clicking `#trigger-button` should ideally fire all four
  (the canonical DOM event flow is: capture from window down to the
  target, then bubble from target up). Drivers that emit a properly
  bubbled+captured event hit all four. Drivers that take shortcuts
  (e.g. raw `el.click()` synthesis) may miss capture-phase listeners
  on intermediate ancestors.
  """
  def event_capture(conn, _params) do
    html(conn, """
    <html><body>
      <div id="root">
        <button id="trigger-button" type="button">Click me</button>
      </div>
      <ul>
        <li>root capture:     <span id="root-capture">0</span></li>
        <li>root bubble:      <span id="root-bubble">0</span></li>
        <li>document capture: <span id="document-capture">0</span></li>
        <li>document bubble:  <span id="document-bubble">0</span></li>
      </ul>
      <script>
        var bump = function(id) {
          return function() {
            var n = document.getElementById(id);
            n.textContent = String(Number(n.textContent) + 1);
          };
        };
        var root = document.getElementById("root");
        root.addEventListener("click", bump("root-capture"), true);
        root.addEventListener("click", bump("root-bubble"), false);
        document.addEventListener("click", bump("document-capture"), true);
        document.addEventListener("click", bump("document-bubble"), false);
      </script>
    </body></html>
    """)
  end

  def show(conn, _params) do
    token = Plug.CSRFProtection.get_csrf_token()

    html(conn, """
    <html><body>
      <form id="plain-form" action="/plain-form" method="post">
        <input type="hidden" name="_csrf_token" value="#{token}" />
        <button id="plain-submit" type="submit">Submit</button>
      </form>
    </body></html>
    """)
  end

  def submit(conn, _params) do
    redirect(conn, to: "/full-nav-dest")
  end

  def trigger_action_target(conn, _params) do
    redirect(conn, to: "/full-nav-dest")
  end

  # Plain HTML page that emulates a LiveView page mid-join: it presents
  # a window.liveSocket object whose main.joinPending starts `true` and
  # flips to `false` 100ms after install. Clicking the button records
  # whether the click landed before/after the flip — wallabidi should
  # give the channel its 200ms-default pre-click window to finish join
  # rather than firing immediately into a stale handler-binding window.
  def join_pending(conn, _params) do
    # No <script> at initial parse: window.liveSocket is absent when
    # visit()'s await_liveview_connected runs, so visit() returns
    # immediately (document has no [data-phx-session]).
    #
    # Then at T+50ms we INSTALL a fake liveSocket with joinPending=true
    # and also mark the page as a LiveView via [data-phx-session]. At
    # T+850ms we flip joinPending → false. Our click_full op should
    # wait for that flip before dispatching; without the fix the click
    # lands in the 50–850ms pending window and the delta is negative.
    html(conn, """
    <html>
      <body>
        <button id="jp-button" phx-click="ignored" onclick="document.getElementById('jp-output').textContent = (window.__joinFlipAt === 0 ? 'clicked-while-pending' : 'clicked-after-flip');">
          Click me
        </button>
        <span id="jp-output">unclicked</span>
        <script>
          // Install immediately so wallabidi sees joinPending=true at
          // click time. Flip 100ms later — well within wallabidi's
          // 200ms pre-click window, so the click should land after.
          window.__joinFlipAt = 0;
          document.body.setAttribute('data-phx-session', 'fake');
          window.liveSocket = {
            main: { joinPending: true },
            domCallbacks: { onPatchEnd: function(){} }
          };
          setTimeout(function() {
            window.__joinFlipAt = Date.now();
            window.liveSocket.main.joinPending = false;
          }, 100);
        </script>
      </body>
    </html>
    """)
  end
end
