#!/usr/bin/env bash
# Regenerates mayhem/base_ext.sparse (the committed ext4 base image of the btrfs-convert target). Not run
# by build.sh: the output is committed so the fuzz binaries are reproducible.
# Usage: mayhem/gen_ext_image.sh [out]   (needs mke2fs >= 1.45 and python3)
# metadata_csum and uninit_bg are off: libext2fs verifies those checksums when it opens the image, so a
# mutated byte would be rejected before btrfs-convert's own code ran. 128 MiB is the smallest size at
# which btrfs-convert can reserve its 32 MiB metadata chunk.
set -euo pipefail
OUT=$(realpath -m "${1:-$(dirname "$0")/base_ext.sparse}")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
R=$W/root; mkdir -p "$R/dir/sub" "$R/empty"
printf 'hello ext4\n' > "$R/small.txt"
python3 - "$R" <<'PY'
import sys, random, os
r = sys.argv[1]
random.seed(11)
words = ["alpha", "beta", "gamma", "delta", "ext4", "extent", "inline", "tree"]
open(r + "/dir/text.txt", "w").write(" ".join(random.choice(words) for _ in range(6000)))
open(r + "/dir/tiny.txt", "w").write("tiny inline file\n")
open(r + "/dir/sub/rand.bin", "wb").write(bytes(random.getrandbits(8) for _ in range(9000)))
open(r + "/dir/zero.bin", "wb").write(b"\0" * 20000)
with open(r + "/dir/holes.bin", "wb") as f:
    f.write(b"A" * 5000); f.seek(1 << 20); f.write(b"B" * 5000); f.seek(5 << 20); f.write(b"C" * 100)
open(r + "/dir/nonempty-xattr.txt", "w").write("has xattrs\n")
os.setxattr(r + "/dir/nonempty-xattr.txt", "user.k", b"value")
os.symlink("dir/text.txt", r + "/link")
os.symlink("x" * 100, r + "/longlink")
os.link(r + "/small.txt", r + "/dir/hard.txt")
os.mkfifo(r + "/fifo")
PY
find "$R" -exec touch -h -d @1700000000 {} +
IMG=$W/img; truncate -s 128M "$IMG"
E2FSPROGS_FAKE_TIME=1700000000 mke2fs -q -t ext4 -b 4096 -N 256 -L mayhem \
  -U 11111111-2222-3333-4444-555555555555 -E hash_seed=66666666-7777-8888-9999-aaaaaaaaaaaa,lazy_itable_init=0,root_owner=0:0 \
  -O ^metadata_csum,^uninit_bg,^64bit,^has_journal,^resize_inode -d "$R" -F "$IMG"
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
