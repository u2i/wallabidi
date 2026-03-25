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
end
