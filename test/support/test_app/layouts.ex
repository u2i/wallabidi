defmodule Wallabidi.TestApp.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head><title>Test App</title></head>
    <body>{@inner_content}</body>
    </html>
    """
  end
end
