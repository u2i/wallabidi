defmodule Wallabidi.Integration.Helpers do
  @moduledoc false

  def displayed_in_viewport?(session, %Wallabidi.Query{} = query) do
    # Use visible: :any since this helper's whole job is to distinguish
    # elements-in-DOM from elements-in-viewport (regardless of visibility)
    query = %{query | conditions: Keyword.put(query.conditions, :visible, :any)}
    displayed_in_viewport?(session, Wallabidi.Browser.find(session, query))
  end

  # Checks if an element's center is within the viewport and not covered
  # by other elements. Uses elementFromPoint which naturally handles overflow
  # clipping, scroll position, and z-index ordering — works identically across
  # BiDi and CDP drivers.
  def displayed_in_viewport?(session, %Wallabidi.Element{} = element) do
    {:ok, result} =
      element.driver.execute_script(
        session,
        """
        const elem = arguments[0]
        if (!elem) return false

        const style = window.getComputedStyle(elem)
        if (style.display === 'none' ||
            style.visibility === 'hidden' ||
            parseFloat(style.opacity) === 0) return false

        const rect = elem.getBoundingClientRect()
        const vw = document.documentElement.clientWidth
        const vh = document.documentElement.clientHeight

        // Element center
        const cx = rect.left + rect.width / 2
        const cy = rect.top + rect.height / 2

        // Outside viewport
        if (cx < 0 || cy < 0 || cx > vw || cy > vh) return false

        // Check that the element (or a descendant) is the topmost at its center
        const topmost = document.elementFromPoint(cx, cy)
        return topmost === elem || elem.contains(topmost)
        """,
        [%{"element-6066-11e4-a52e-4f735466cecf" => element.id, "ELEMENT" => element.id}]
      )

    result
  end
end
