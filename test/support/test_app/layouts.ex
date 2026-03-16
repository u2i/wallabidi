defmodule Wallabidi.TestApp.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <title>Test App</title>
      <script src="/assets/phoenix/phoenix.min.js"></script>
      <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
      <script>
        window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket);
        window.liveSocket.connect();
      </script>
    </head>
    <body>{@inner_content}</body>
    </html>
    """
  end
end
