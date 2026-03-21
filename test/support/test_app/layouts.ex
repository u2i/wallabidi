defmodule Wallabidi.TestApp.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <title>Test App</title>
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()}/>
      <script src="/assets/phoenix/phoenix.min.js"></script>
      <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
      <script>
        let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
        window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
          params: {_csrf_token: csrfToken}
        });
        window.liveSocket.connect();
      </script>
    </head>
    <body>{@inner_content}</body>
    </html>
    """
  end
end
