import QtQuick
import "../services"
import "../model/Bytes.js" as Bytes
import "../model/Media.js" as Media

// Album art, from a URL that any process on the session bus can publish.
//
// Neither kind of cover reaches an Image as the player gave it. A remote one
// is downloaded by the helper, where curl stops an oversized or stalled
// response at the socket. A local one is copied by the same helper, because a
// path is not safer than a URL: Qt runs one image-reader thread per engine and
// the shell is one engine, so a path whose open() blocks — a FIFO with no
// writer is enough — parks that thread for good and every other image in the
// shell with it. The helper refuses anything that is not a regular file, reads
// it under a timeout, and copies it.
//
// So an Image here only ever points at a file this plugin wrote, and the type
// is decided three times by the same rule: the helper gates on magic bytes and
// on the declared pixel dimensions, and the bytes are checked again here.
Item {
  id: root

  property string url: ""
  property int maxBytes: 1024 * 1024
  // The decode bound, separate from the byte bound: an image inside its budget
  // can still be enormous in pixels.
  property int decodeSize: 256

  readonly property bool local: Media.isLocalArt(url)
  readonly property bool ready: image.status === Image.Ready

  // The helper takes a path for a local cover and a URL for a remote one.
  readonly property string source: local ? Media.localArtPath(url) : url

  property string fetchedPath: ""

  onUrlChanged: {
    fetchedPath = ""
    verify.path = ""
    fetcher.cancel()
    // Coalesced: a player that rewrites its metadata in a loop should cost one
    // copy or one fetch, not one per write.
    if (source !== "") debounce.restart()
    else debounce.stop()
  }

  Timer {
    id: debounce
    interval: 250
    onTriggered: fetcher.get(root.source)
  }

  Fetcher {
    id: fetcher
    name: "art"
    kind: root.local ? "local-image" : "image"
    maxBytes: root.maxBytes
    onFetched: function (path) {
      verify.path = path
      verify.reload()
    }
    onFailed: function (code) { root.fetchedPath = "" }
  }

  // Bounded on the way in as well: the helper wrote this file, but a read with
  // no ceiling is the thing this plugin has twice been told not to do.
  GuardedFile {
    id: verify
    binary: true
    maxBytes: root.maxBytes
    onBytesLoaded: function (bytes) {
      root.fetchedPath = Bytes.imageType(bytes) === "" ? "" : "file://" + path
    }
    onMissing: root.fetchedPath = ""
  }

  Image {
    id: image
    anchors.fill: parent
    source: root.fetchedPath
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    sourceSize.width: root.decodeSize
    sourceSize.height: root.decodeSize
  }
}
