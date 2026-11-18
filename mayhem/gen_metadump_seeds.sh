#!/bin/bash
# Usage: gen_metadump_seeds.sh <btrfs-image> <outdir>: metadump seeds for btrfs_image, made from mayhem/base.sparse.
set -euo pipefail
BI=$(realpath "$1"); OUT=$(realpath "$2"); HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
python3 - "$HERE/base.sparse" "$W/base.img" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<I", d)[0]
with open(sys.argv[2], "wb") as f:
    f.truncate(n * 4096)
    for o in range(4, len(d), 4100):
        f.seek(struct.unpack_from("<I", d, o)[0] * 4096)
        f.write(d[o + 4:o + 4100])
PY
mkdir -p "$OUT"
"$BI" -c0 "$W/base.img" "$OUT/dump-c0.img" >/dev/null
"$BI" -c0 -s "$W/base.img" "$OUT/dump-c0-sanitize.img" >/dev/null
"$BI" -c1 "$W/base.img" "$OUT/dump-c1.img" >/dev/null
"$BI" -c0 -t2 -m "$W/base.img" "$OUT/dump-c0-multi.img" >/dev/null 2>&1 || true
rm -f "$OUT"/*.1 2>/dev/null || true
ls -l "$OUT"
