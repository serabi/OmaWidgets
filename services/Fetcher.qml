import QtQuick
import Quickshell
import Quickshell.Io

// Runs scripts/omawidgets-fetch and says where the file landed.
//
// Nothing inside the shell process opens a socket: Quickshell's
// XMLHttpRequest cannot bound a response — binary is unreadable until it is
// complete, and text was measured carrying 1.5 MB into its first readable
// moment against a 64 KB cap — so a check in QML always runs after the memory
// has been taken. The helper lets curl stop at the socket instead.
Item {
  id: root

  property int maxBytes: 64 * 1024
  // "any", "image", or "local-image" for a file already on this machine. An
  // image has to be one by its own magic bytes either way.
  property string kind: "any"
  property string name: "fetched"

  // No fallback: UID is a shell variable and is never in the environment, so
  // the old one composed /run/user//omawidgets and every fetch failed closed
  // with an obscure code. Without a runtime directory there is nowhere this
  // may write, and saying so here is clearer than the helper refusing later.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string directory: runtimeDir === "" ? "" : runtimeDir + "/omawidgets"
  readonly property bool available: directory !== "" && scriptPath !== ""
  readonly property string scriptPath: localPath(Qt.resolvedUrl("../scripts/omawidgets-fetch"))

  readonly property bool busy: process.running

  signal fetched(string path)
  signal failed(int code)

  function localPath(fileUrl) {
    var text = String(fileUrl || "")
    if (text.indexOf("file://") !== 0) return ""
    return decodeURIComponent(text.substring(7))
  }

  // One file per URL, so a cached Image is never a stale cover and two fetches
  // cannot write over each other.
  function pathFor(source) {
    return directory + "/" + name + "-" + Qt.md5(String(source || "")) + ".img"
  }

  function get(source) {
    if (!available || String(source || "") === "") return
    var destination = pathFor(source)
    // A new request replaces one still running: an MPRIS player that changes
    // its artwork in a loop should cost one fetch at a time, not one per
    // change.
    if (process.running) process.running = false
    process.destination = destination
    // Through bash rather than execing the script, so a checkout that lost its
    // exec bit still works — the same reason HardwareProbe does it.
    process.command = ["bash", "--", scriptPath, source, destination, String(maxBytes), kind]
    process.running = true
  }

  function cancel() {
    if (process.running) process.running = false
  }

  Process {
    id: process
    property string destination: ""
    onExited: function (code) {
      if (code === 0) root.fetched(destination)
      else root.failed(code)
    }
  }

  Component.onDestruction: cancel()
}
