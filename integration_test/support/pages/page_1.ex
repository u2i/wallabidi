defmodule Wallabidi.Integration.Pages.Page1 do
  use Wallabidi.DSL

  def visit(session) do
    session
    |> visit("page_1.html")
  end

  def ensure_page_loaded(session) do
    session
    |> Browser.find(Query.css(".page-1-page"))

    session
  end
end
