defmodule Wallabidi.Integration.LiveApp.PlainFormController do
  use Phoenix.Controller, formats: [:html]

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
