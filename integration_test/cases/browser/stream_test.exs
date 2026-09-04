defmodule Wallabidi.Integration.Browser.StreamTest do
  use Wallabidi.Integration.SessionCase, async: false
  @moduletag :browser

  setup %{session: session} do
    {:ok, page: visit(session, "/")}
  end

  test "open_stream delivers page-pushed chunks in order", %{page: page} do
    {:ok, stream_id} = open_stream(page)
    stream_id_js = Jason.encode!(stream_id)

    execute_script(page, """
    for (let i = 0; i < 5; i++) {
      window.__wallabidi_stream(#{stream_id_js}, "chunk-" + i);
    }
    """)

    for i <- 0..4 do
      expected = "chunk-#{i}"
      assert_receive {:wallabidi_stream, ^stream_id, ^i, ^expected}, 5_000
    end

    :ok = close_stream(page, stream_id)
  end

  test "chunks pushed after close_stream are not delivered", %{page: page} do
    {:ok, stream_id} = open_stream(page)
    stream_id_js = Jason.encode!(stream_id)

    execute_script(page, "window.__wallabidi_stream(#{stream_id_js}, \"before-close\");")
    assert_receive {:wallabidi_stream, ^stream_id, 0, "before-close"}, 5_000

    :ok = close_stream(page, stream_id)

    execute_script(page, "window.__wallabidi_stream(#{stream_id_js}, \"after-close\");")
    refute_receive {:wallabidi_stream, ^stream_id, _seq, "after-close"}, 1_000
  end
end
