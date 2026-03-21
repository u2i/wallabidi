defmodule Wallabidi.Integration.LiveApp.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <script src="https://cdn.jsdelivr.net/npm/phoenix@1.8.5/priv/static/phoenix.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.27/priv/static/phoenix_live_view.min.js"></script>
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()}/>
      <script>
        let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
        let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
          params: {_csrf_token: csrfToken}
        });
        liveSocket.connect();
        window.liveSocket = liveSocket;
      </script>
    </head>
    <body>
      {@inner_content}
    </body>
    </html>
    """
  end
end
