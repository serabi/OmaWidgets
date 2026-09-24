#!/usr/bin/env bash
#
# The fetch helper, against a server written to be hostile.
#
# Every network read this plugin performs goes through that script, so its exit
# codes are the whole contract: nothing else decides whether an oversized, slow
# or mistyped response is allowed to become a file.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip fetch — python3 not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip fetch — curl not installed"; exit 0; }

RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
OUT_DIR="$RUNTIME/omawidgets/test-fetch"
# A private script and a port the kernel picks: a predictable temporary and a
# fixed port both let another local process answer these cases in the test
# server's place, and a suite that can be made to pass vacuously is worse than
# no suite.
SERVER=$(mktemp "${TMPDIR:-/tmp}/omawidgets-hostile.XXXXXXXX.py")
PORT_FILE=$(mktemp "${TMPDIR:-/tmp}/omawidgets-port.XXXXXXXX")
SCRIPT=./scripts/omawidgets-fetch
status=0
passed=0

cat > "$SERVER" <<PY
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/flood":                      # chunked, never declared, never ends
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            chunk = b"A" * 65536
            try:
                for _ in range(4096): self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n"); self.wfile.flush()
            except Exception: pass
        elif self.path == "/declared":                  # 50 MB, declared
            self.send_response(200); self.send_header("Content-Length", str(50 * 1024 * 1024)); self.end_headers()
            try:
                for _ in range(800): self.wfile.write(b"B" * 65536); self.wfile.flush()
            except Exception: pass
        elif self.path == "/stall":                     # headers, then nothing
            self.send_response(200); self.send_header("Content-Length", "100"); self.end_headers(); time.sleep(600)
        elif self.path == "/html-as-png":               # a lie about the type
            body = b"<html>not an image</html>"
            self.send_response(200); self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == "/png":
            png = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6360000002000100ffff03000006000557bfabd40000000049454e44ae426082")
            self.send_response(200); self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(png))); self.end_headers(); self.wfile.write(png)
        elif self.path == "/slow":
            self.send_response(200); self.send_header("Content-Length", "1000"); self.end_headers()
            time.sleep(30)
        elif self.path == "/exact":
            body = b"E" * 64
            self.send_response(200); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        elif self.path.startswith("/loop"):
            n = int(self.path[5:] or 0)
            self.send_response(302); self.send_header("Location", "/loop%d" % (n + 1))
            self.send_header("Content-Length", "0"); self.end_headers()
        elif self.path == "/bomb":
            import struct, zlib
            def chunk(t, d):
                return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
            body = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">II", 20000, 20000) + bytes([8, 0, 0, 0, 0])) + chunk(b"IEND", b"")
            self.send_response(200); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        elif self.path == "/redirect-to-file":
            self.send_response(302); self.send_header("Location", "file:///etc/passwd")
            self.send_header("Content-Length", "0"); self.end_headers()
        elif self.path.startswith("/many"):
            body = bytes.fromhex("89504e470d0a1a0a") + b"x" * 64
            self.send_response(200); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        elif self.path == "/json":
            body = b'{"version":"9.9.9"}'
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$SERVER" "$PORT_FILE" & server=$!
trap 'kill $server 2>/dev/null; rm -f "$SERVER" "$PORT_FILE"; rm -rf "$OUT_DIR"' EXIT
PORT=""
for _ in $(seq 60); do PORT=$(cat "$PORT_FILE" 2>/dev/null); [[ -n $PORT ]] && break; sleep 0.1; done
[[ -n $PORT ]] || { echo "FAIL fetch — the test server never reported a port"; exit 1; }
for _ in $(seq 40); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/json" && break; sleep 0.1; done

check() {
  local want=$1 what=$2; shift 2
  rm -f "$OUT_DIR/out.img"
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got == "$want" ]]; then
    passed=$((passed + 1))
  else
    printf '     %-46s expected %s, got %s\n' "$what" "$want" "$got"
    status=1
  fi
}

base="http://127.0.0.1:$PORT"
check 5 "a chunked flood is cut at the cap"        $SCRIPT "$base/flood" "$OUT_DIR/out.img" 65536
check 5 "a declared 50 MB body is refused"         $SCRIPT "$base/declared" "$OUT_DIR/out.img" 65536
check 5 "headers then silence runs out of time"    $SCRIPT "$base/stall" "$OUT_DIR/out.img" 65536
check 9 "html served as image/png is not an image" $SCRIPT "$base/html-as-png" "$OUT_DIR/out.img" 65536 image
check 0 "a real png is fetched"                    $SCRIPT "$base/png" "$OUT_DIR/out.img" 65536 image
check 0 "and so is a small json body"              $SCRIPT "$base/json" "$OUT_DIR/out.img" 65536
check 9 "a json body is not an image"              $SCRIPT "$base/json" "$OUT_DIR/out.img" 65536 image

check 3 "a file:// url is refused"                 $SCRIPT "file:///etc/passwd" "$OUT_DIR/out.img" 65536
check 3 "a command substitution is refused"        $SCRIPT 'http://x/$(id)' "$OUT_DIR/out.img" 65536
check 3 "a backtick is refused"                    $SCRIPT 'http://x/`id`' "$OUT_DIR/out.img" 65536
check 3 "a cap that is not a number is refused"    $SCRIPT "$base/json" "$OUT_DIR/out.img" 64kb
check 3 "a cap above the hard ceiling is refused"  $SCRIPT "$base/json" "$OUT_DIR/out.img" 99999999
check 4 "a destination outside the runtime dir"    $SCRIPT "$base/json" "/tmp/omawidgets-escape.img" 65536
check 4 "a destination that climbs out of it"      $SCRIPT "$base/json" "$OUT_DIR/../../../escape.img" 65536
check 2 "no arguments at all"                      $SCRIPT
check 5 "a redirect off http(s) is not followed"   $SCRIPT "$base/redirect-to-file" "$OUT_DIR/out.img" 65536

check 7 "a body exactly at the cap is discarded"   $SCRIPT "$base/exact" "$OUT_DIR/out.img" 64
check 5 "a redirect loop runs out of hops"         $SCRIPT "$base/loop" "$OUT_DIR/out.img" 65536
check 11 "a 20000x20000 declaration is refused"    $SCRIPT "$base/bomb" "$OUT_DIR/out.img" 65536 image
check 4 "a destination ending in a slash"          $SCRIPT "$base/json" "$OUT_DIR/" 65536
check 3 "an unknown mode"                          $SCRIPT "$base/json" "$OUT_DIR/out.img" 65536 wat

# Local covers go through the same helper, because a path that blocks on open
# parks Qt's one image-reader thread for the whole shell.
mkdir -p "$OUT_DIR"
fifo="$OUT_DIR/blocking.fifo"; rm -f "$fifo"; mkfifo "$fifo"
printf '\x89PNG\r\n\x1a\n' > "$OUT_DIR/not-really.png"
check 10 "a local FIFO is not a regular file"      $SCRIPT "$fifo" "$OUT_DIR/out.img" 65536 local-image
check 10 "a local directory is not one either"     $SCRIPT "$OUT_DIR" "$OUT_DIR/out.img" 65536 local-image
check 10 "and neither is a character device"       $SCRIPT "/dev/zero" "$OUT_DIR/out.img" 65536 local-image
check 10 "a local file that is not there"          $SCRIPT "$OUT_DIR/absent.png" "$OUT_DIR/out.img" 65536 local-image
check 3 "a relative local path"                    $SCRIPT "relative.png" "$OUT_DIR/out.img" 65536 local-image
check 9 "a local file that is only a PNG header"   $SCRIPT "$OUT_DIR/not-really.png" "$OUT_DIR/out.img" 65536 local-image
rm -f "$fifo"

# A player that rewrites its artwork in a loop must not be able to fill a tmpfs.
for i in $(seq 12); do
  $SCRIPT "$base/many?$i" "$OUT_DIR/art-$i.img" 65536 >/dev/null 2>&1
done
kept=$(ls -1 "$OUT_DIR"/art-*.img 2>/dev/null | wc -l)
# Exactly eight, and the newest among them: "at most eight" also passes when
# pruning deleted everything, or when all twelve fetches failed.
if (( kept == 8 )) && [[ -s "$OUT_DIR/art-12.img" ]]; then
  passed=$((passed + 1))
else
  printf '     %-46s expected 8 kept including the newest, found %s\n' \
    "twelve fetches prune down to the newest" "$kept"
  status=1
fi

# Cancelling must take the download with it: a SIGTERM that leaves curl running
# means two fetches overlap, each still pulling up to the cap, and the caller
# cancels on every artwork change.
mkdir -p "$OUT_DIR"
$SCRIPT "$base/slow" "$OUT_DIR/cancel.img" 65536 &
helper=$!
sleep 1
before=$(pgrep -a curl 2>/dev/null | grep -c "$PORT/slow")
kill -TERM $helper 2>/dev/null
sleep 1
after=$(pgrep -a curl 2>/dev/null | grep -c "$PORT/slow")
leftover=$(find "$OUT_DIR" -maxdepth 1 -name '.fetch.*' 2>/dev/null | wc -l)
if (( before == 1 && after == 0 && leftover == 0 )); then
  passed=$((passed + 1))
else
  printf '     %-46s curl before=%s after=%s temporaries=%s\n' \
    "cancelling the helper kills the download" "$before" "$after" "$leftover"
  status=1
fi

if ((status == 0)); then
  echo "ok   fetch — $passed hostile cases refused or served as specified"
else
  echo "FAIL fetch — see above"
fi
exit $status
