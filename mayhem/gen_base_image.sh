#!/usr/bin/env bash
# Regenerates mayhem/base.sparse (the committed fuzzing base image). Not run by build.sh: the output is
# committed so the fuzz binaries are reproducible. Usage: mayhem/gen_base_image.sh <mkfs.btrfs> [out]
set -euo pipefail
MKFS=$(realpath "$1"); OUT=$(realpath -m "${2:-$(dirname "$0")/base.sparse}")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
R=$W/root; mkdir -p "$R/dir/sub" "$R/vol" "$R/rovol"
printf 'hello btrfs\n' > "$R/small.txt"
python3 - "$R" <<'PY'
import sys, random
r = sys.argv[1]
random.seed(7)
words = ["alpha", "beta", "gamma", "delta", "btrfs", "extent", "inline", "tree"]
open(r + "/dir/text.txt", "w").write(" ".join(random.choice(words) for _ in range(6000)))
open(r + "/dir/inline.txt", "w").write(" ".join(random.choice(words) for _ in range(550)))
open(r + "/dir/sub/rand.bin", "wb").write(bytes(random.getrandbits(8) for _ in range(9000)))
open(r + "/vol/data.txt", "w").write("subvolume data\n" * 700)
open(r + "/rovol/ro.txt", "w").write("read only subvolume\n" * 50)
open(r + "/dir/zero.bin", "wb").write(b"\0" * 20000)
PY
ln -s dir/text.txt "$R/link"
ln "$R/small.txt" "$R/dir/hard.txt"
mkfifo "$R/fifo"
python3 -c 'import os,sys; os.setxattr(sys.argv[1]+"/small.txt","user.k",b"value")' "$R" 2>/dev/null || echo "note: no xattr support here" >&2
find "$R" -exec touch -h -d @1700000000 {} +
IMG=$W/img; truncate -s 16M "$IMG"
"$MKFS" -q -f -b 16M -U 11111111-2222-3333-4444-555555555555 --device-uuid 66666666-7777-8888-9999-aaaaaaaaaaaa \
  -L mayhem -O quota -n 16K -m single -d single --shrink --compress lzo -r "$R" -u rw:vol -u ro:rovol "$IMG"
python3 - "$IMG" "$OUT" <<'PY'
import sys, struct
img, out = sys.argv[1:]
d = open(img, "rb").read()
with open(out, "wb") as f:
    f.write(struct.pack("<I", len(d) // 4096))
    for i in range(0, len(d), 4096):
        b = d[i:i + 4096]
        if b.count(0) != 4096:
            f.write(struct.pack("<I", i // 4096) + b)
PY
ls -l "$OUT"
