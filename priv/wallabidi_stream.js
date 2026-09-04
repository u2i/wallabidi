// Browser-side helper for wallabidi's CDP streaming channel.
//
// Exposes window.__wallabidi_stream(streamId, blobOrBufferOrView) —
// call this from your own capture code (e.g. a MediaRecorder's
// ondataavailable) to push one chunk to the Elixir side. Chunks for
// the same streamId are delivered in the order you call this in;
// each streamId tracks its own sequence counter.
//
// Wraps __wallabidi_stream_raw (the CDP binding installed by
// Wallabidi.Remote.CDP.Client.install_stream_binding/1) as a JSON
// envelope: {streamId, seq, data: base64}. See
// Wallabidi.Remote.Transport.Common's "Streaming" section for the
// Elixir-side delivery.
//
// Source of truth: this file. Wallabidi.Remote.CDP.Client embeds it
// at compile time via @external_resource + File.read!.

if (!window.__wallabidi_stream) {
  window.__wallabidi_stream_seq = {};

  window.__wallabidi_stream = function (streamId, chunk) {
    var seqMap = window.__wallabidi_stream_seq;
    var seq = seqMap[streamId] || 0;
    seqMap[streamId] = seq + 1;

    toArrayBuffer(chunk).then(function (buf) {
      var b64 = arrayBufferToBase64(buf);
      window.__wallabidi_stream_raw(JSON.stringify({ streamId: streamId, seq: seq, data: b64 }));
    });
  };

  function toArrayBuffer(chunk) {
    if (chunk instanceof Blob) return chunk.arrayBuffer();
    if (chunk instanceof ArrayBuffer) return Promise.resolve(chunk);
    if (ArrayBuffer.isView(chunk)) return Promise.resolve(chunk.buffer);
    return Promise.resolve(new TextEncoder().encode(String(chunk)).buffer);
  }

  function arrayBufferToBase64(buf) {
    var bytes = new Uint8Array(buf);
    var chunkSize = 0x8000;
    var binary = '';

    for (var i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }

    return btoa(binary);
  }
}
