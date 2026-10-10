#!/usr/bin/env bash
#
# What a fetched file is allowed to be, from the file's own bytes.
#
# The dimension half of this is what the marketplace review of 2c11e82 found
# missing for JPEG: PNG, GIF and BMP carry their size at a fixed offset, so
# they were bounded, while a JPEG keeps it in a frame header that sits after a
# variable run of segments — and a progressive one makes libjpeg allocate for
# the whole canvas before anything scales it down.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=../scripts/omawidgets-image-check
source ./scripts/omawidgets-image-check

status=0
passed=0
work=$(mktemp -d "${TMPDIR:-/tmp}/omawidgets-image.XXXXXX")
trap 'rm -rf "$work"' EXIT

build() {
  python3 - "$work/$1" "$2" "${3:-}" <<'PY'
import struct, sys, zlib
path, kind, arg = sys.argv[1], sys.argv[2], sys.argv[3]
w, h = (int(x) for x in arg.split("x")) if "x" in arg else (1, 1)

def png(w, h):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">II", w, h) + bytes([8, 0, 0, 0, 0]))
            + chunk(b"IDAT", zlib.compress(b"\x00" * 16)) + chunk(b"IEND", b""))

def jpeg(w, h, progressive=False, frame=True, pad=0):
    out = b"\xff\xd8" + b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    if pad:                                   # an EXIF-sized segment before the frame
        out += b"\xff\xe1" + struct.pack(">H", pad + 2) + b"\x00" * pad
    if frame:
        out += (b"\xff\xc2" if progressive else b"\xff\xc0") + struct.pack(">H", 17) + bytes([8])
        out += struct.pack(">HH", h, w) + bytes([3, 1, 17, 0, 2, 17, 1, 3, 17, 1])
    return out + b"\xff\xda" + struct.pack(">H", 8) + bytes([1, 1, 0, 0, 63, 0]) + b"\x00" * 64 + b"\xff\xd9"

bodies = {
    "png": lambda: png(w, h),
    "jpeg": lambda: jpeg(w, h),
    "jpeg-progressive": lambda: jpeg(w, h, progressive=True),
    "jpeg-noframe": lambda: jpeg(w, h, frame=False),
    "jpeg-padded": lambda: jpeg(w, h, pad=40000),
    "jpeg-far": lambda: jpeg(w, h, pad=65000) + b"",   # frame beyond a 128 KB walk when doubled
    "gif": lambda: b"GIF89a" + struct.pack("<HH", w, h) + b"\x80\x00\x00" + b"\x00" * 32,
    "bmp": lambda: b"BM" + struct.pack("<I", 70) + b"\x00" * 12 + struct.pack("<ii", w, h) + b"\x00" * 40,
    "html": lambda: b"<html>not an image</html>" + b"\x00" * 32,
    "svg": lambda: b"<svg xmlns='http://www.w3.org/2000/svg'></svg>" + b"\x00" * 32,
    "short": lambda: b"\x89PNG\r\n\x1a\n",
}
open(path, "wb").write(bodies[kind]())
PY
}

check() {
  local want=$1 what=$2 file=$3
  omawidgets_image_check "$work/$file"
  local got=$?
  if [[ $got == "$want" ]]; then
    passed=$((passed + 1))
  else
    printf '     %-52s expected %s, got %s\n' "$what" "$want" "$got"
    status=1
  fi
}

build cover.png png 600x600;                   check 0 "a cover-sized PNG" cover.png
build cover.jpg jpeg 600x600;                  check 0 "a cover-sized JPEG" cover.jpg
build cover.gif gif 600x600;                   check 0 "a cover-sized GIF" cover.gif
build cover.bmp bmp 600x600;                   check 0 "a cover-sized BMP" cover.bmp
build padded.jpg jpeg-padded 600x600;          check 0 "a JPEG behind a 40 KB segment" padded.jpg

build big.png png 20000x20000;                 check 11 "a 20000x20000 PNG" big.png
build big.jpg jpeg 9000x9000;                  check 11 "a 9000x9000 JPEG" big.jpg
build bigprog.jpg jpeg-progressive 9000x9000;  check 11 "a 9000x9000 progressive JPEG" bigprog.jpg
build wide.jpg jpeg 8000x4000;                 check 11 "a JPEG inside the side cap but over the area" wide.jpg
build wide.png png 8000x4000;                  check 11 "and a PNG of the same shape" wide.png
build edge.jpg jpeg 4096x4096;                 check 0 "4096x4096 is exactly the area cap" edge.jpg
build edge2.jpg jpeg 8192x2048;                check 0 "and so is 8192x2048, at the side cap" edge2.jpg

build noframe.jpg jpeg-noframe 600x600;        check 9 "a JPEG with no frame header" noframe.jpg
build page.html html 1x1;                      check 9 "HTML, whatever it was served as" page.html
build vector.svg svg 1x1;                      check 9 "SVG, which is a document with scripting" vector.svg
build tiny.bin short 1x1;                      check 9 "a file too short to carry a header" tiny.bin

if ((status == 0)); then
  echo "ok   image-check — $passed cases, including the JPEG gap from the 1.9.4 review"
else
  echo "FAIL image-check — see above"
fi
exit $status
