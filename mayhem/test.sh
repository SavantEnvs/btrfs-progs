#!/usr/bin/env bash
#
# mayhem/test.sh — tests of the normal-flags btrfs binaries built by mayhem/build.sh (/mayhem/oracle):
# known-answer checks that assert concrete output or restored-data hashes, then upstream's own
# tests/fsck-tests cases (check, repair, re-check) through tests/common, the root-free misc/cli cases and
# upstream CI's unit tests (test-api, hash-vectest).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


O=${ORACLE_DIR:-$SRC/mayhem/oracle}
for b in btrfs mkfs.btrfs btrfs-image btrfs-convert json-formatter-test string-table-test array-test hash-vectest; do
  [ -x "$O/$b" ] || { echo "missing $O/$b (mayhem/build.sh builds it)" >&2; emit_ctrf "btrfs-progs-kat" 0 1 0; exit 1; }
done
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
passed=0; failed=0
t() { # t <name> <command...>: pass iff the command succeeds
  local name="$1"; shift
  if "$@" >"$W/last.out" 2>&1; then passed=$((passed+1)); echo "PASS $name"
  else failed=$((failed+1)); echo "FAIL $name"; sed 's/^/   | /' "$W/last.out" | head -20; fi
}
has() { grep -Eq -- "$1" "$W/out"; }

# --- fixture: a filesystem with known content, built by the oracle mkfs --------------------------
R=$W/root; mkdir -p "$R/dir" "$R/vol"
printf 'hello btrfs\n' > "$R/small.txt"
python3 -c 'import sys; sys.stdout.write("alpha beta gamma delta\n" * 3000)' > "$R/dir/big.txt"
python3 -c 'import sys; sys.stdout.write("subvolume data\n" * 100)' > "$R/vol/data.txt"
ln -s dir/big.txt "$R/link"
IMG=$W/kat.img; truncate -s 16M "$IMG"
"$O/mkfs.btrfs" -q -f -L KATLABEL -U 0a0b0c0d-1111-2222-3333-444455556666 -m single -d single --shrink \
    --compress lzo -r "$R" -u rw:vol "$IMG" >"$W/mkfs.out" 2>&1 || { cat "$W/mkfs.out"; failed=$((failed+1)); }

BIG_SHA=$(python3 -c 'import hashlib; print(hashlib.sha256(b"alpha beta gamma delta\n" * 3000).hexdigest())')
SMALL_SHA=$(printf 'hello btrfs\n' | sha256sum | cut -d' ' -f1)

"$O/btrfs" check --readonly "$IMG" >"$W/out" 2>&1; rc=$?
t "check: clean image has no errors" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"
"$O/btrfs" check --readonly --mode=lowmem "$IMG" >"$W/out" 2>&1; rc=$?
t "check lowmem: clean image has no errors" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"

"$O/btrfs" inspect-internal dump-super "$IMG" >"$W/out" 2>&1
t "dump-super: label" has '^label[[:space:]]+KATLABEL$'
t "dump-super: fsid" has '^fsid[[:space:]]+0a0b0c0d-1111-2222-3333-444455556666$'
t "dump-super: csum type" has '^csum_type[[:space:]]+0 \(crc32c\)$'

"$O/btrfs" inspect-internal dump-tree -t fs "$IMG" >"$W/out" 2>&1
t "dump-tree: fs tree lists the file names" bash -c "grep -q 'name: small.txt' '$W/out' && grep -q 'name: big.txt' '$W/out'"
t "dump-tree: fs tree has the symlink entry" bash -c "grep -q 'name: link' '$W/out' && grep -q 'type SYMLINK' '$W/out'"

mkdir "$W/restored"
"$O/btrfs" restore -i -S "$IMG" "$W/restored" >"$W/out" 2>&1
t "restore: small file content" bash -c "[ \"\$(sha256sum < '$W/restored/small.txt' | cut -d' ' -f1)\" = '$SMALL_SHA' ]"
t "restore: lzo-compressed file content" bash -c "[ \"\$(sha256sum < '$W/restored/dir/big.txt' | cut -d' ' -f1)\" = '$BIG_SHA' ]"
t "restore: file size" bash -c "[ \$(stat -c %s '$W/restored/dir/big.txt') -eq 69000 ]"
"$O/btrfs" restore -l "$IMG" >"$W/out" 2>&1
t "restore -l: lists the fs tree root" has 'tree key \(FS_TREE ROOT_ITEM 0\)'

cp "$IMG" "$W/bad.img"; printf '\xff\xff' | dd of="$W/bad.img" bs=1 seek=$((65536 + 0x70)) conv=notrunc status=none
"$O/btrfs" check --readonly "$W/bad.img" >"$W/out" 2>&1; rc=$?
t "check: corrupt superblock is rejected" bash -c "[ $rc -ne 0 ] && grep -q 'superblock checksum mismatch' '$W/out'"
"$O/btrfs" inspect-internal dump-super "$W/bad.img" >"$W/out" 2>&1
t "dump-super: reports the bad checksum" has "^csum[[:space:]]+0x[0-9a-f]+ \\[DON'T MATCH\\]$"

# --- check --repair and btrfs rescue on the clean fixture (they must leave a clean fs clean) ----------
"$O/btrfs" check --repair --force "$IMG" >"$W/out" 2>&1; rc=$?
t "check --repair: clean image stays clean" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"
cp "$IMG" "$W/rescue.img"
"$O/btrfs" rescue super-recover -y "$W/rescue.img" >"$W/out" 2>&1; rc=$?
t "rescue super-recover: valid supers need no recovery" bash -c "[ $rc -eq 0 ] && grep -q 'All supers are valid, no need to recover' '$W/out'"
"$O/btrfs" rescue chunk-recover -y "$W/rescue.img" >"$W/out" 2>&1; rc=$?
t "rescue chunk-recover: consistent chunks are left alone" bash -c "[ $rc -eq 0 ] && grep -q 'Check chunks successfully with no orphans' '$W/out'"
"$O/btrfs" rescue fix-device-size "$W/rescue.img" >"$W/out" 2>&1
t "rescue fix-device-size: sizes already match" has '^No device size related problem found$'
"$O/btrfs" rescue zero-log "$W/rescue.img" >"$W/out" 2>&1
t "rescue zero-log: reports the previous log root" has '^Clearing log on .*, previous log_root 0, level 0$'
"$O/btrfs" inspect-internal dump-super "$W/rescue.img" >"$W/out" 2>&1
t "rescue zero-log: log_root stays 0" has '^log_root[[:space:]]+0$'
"$O/btrfs" rescue fix-data-checksum -r "$W/rescue.img" >"$W/out" 2>&1
t "rescue fix-data-checksum: no mismatch on a clean fs" has '^no data checksum mismatch found$'
"$O/btrfs" rescue clear-space-cache v2 "$W/rescue.img" >"$W/out" 2>&1
t "rescue clear-space-cache v2: cache cleared" has '^free space cache v2 cleared$'
"$O/btrfs" check --readonly "$W/rescue.img" >"$W/out" 2>&1; rc=$?
t "rescue: fs still passes check afterwards" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"
# mkfs -r allocates blocks in readdir order, which differs per filesystem, and --init-csum-tree aborts on some
# of those layouts; one subvolume holding one file gives the same layout everywhere.
CSR=$W/csumroot; mkdir -p "$CSR/vol"
python3 -c 'import sys; sys.stdout.write("alpha beta gamma delta\n" * 3000)' > "$CSR/vol/data.txt"
truncate -s 16M "$W/csum.img"
"$O/mkfs.btrfs" -q -f -m single -d single --shrink --compress lzo -r "$CSR" -u rw:vol "$W/csum.img" >"$W/mkfs2.out" 2>&1 \
    || { cat "$W/mkfs2.out"; failed=$((failed+1)); }
"$O/btrfs" check --repair --force --init-csum-tree "$W/csum.img" >"$W/out" 2>&1; rc=$?
t "check --init-csum-tree: new csum tree is created" bash -c "[ $rc -eq 0 ] && grep -q '^Creating a new CRC tree$' '$W/out'"
"$O/btrfs" check --readonly --check-data-csum "$W/csum.img" >"$W/out" 2>&1; rc=$?
t "check --init-csum-tree: rebuilt csums verify against the data" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out' && grep -q 'total csum bytes: 4$' '$W/out'"
cp "$IMG" "$W/bad-sb.img"; printf '\0\0\0\0\0\0\0\0' | dd of="$W/bad-sb.img" bs=1 seek=$((65536 + 0x40)) conv=notrunc status=none
"$O/btrfs" rescue super-recover -y "$W/bad-sb.img" >"$W/out" 2>&1; rc=$?
t "rescue super-recover: a device without a btrfs magic is not touched" bash -c "[ $rc -ne 0 ] && [ \"\$(cmp -l '$IMG' '$W/bad-sb.img' | wc -l)\" -le 8 ]"

python3 mayhem/gen_stream.py basic "$W/basic.stream"
"$O/btrfs" receive --dump -f "$W/basic.stream" >"$W/out" 2>&1; rc=$?
t "receive --dump: stream parses" bash -c "[ $rc -eq 0 ]"
t "receive --dump: subvol line" has '^subvol +\./snap1 +uuid=01020304-0506-0708-090a-0b0c0d0e0f10 transid=7$'
t "receive --dump: write line" has '^write +\./snap1/dir/file\.txt +offset=0 len=160$'
t "receive --dump: chown line" has '^chown +\./snap1/dir/file\.txt +gid=100 uid=1000$'
printf 'x' | dd of="$W/basic.stream" bs=1 seek=40 conv=notrunc status=none
"$O/btrfs" receive --dump -f "$W/basic.stream" >"$W/out" 2>&1; rc=$?
t "receive --dump: corrupted stream is rejected (crc32c)" bash -c "[ $rc -ne 0 ] && grep -q 'crc32c mismatch' '$W/out'"

"$O/btrfs-image" -c0 "$IMG" "$W/meta.img" >"$W/out" 2>&1; rc=$?
t "btrfs-image: metadump is created" bash -c "[ $rc -eq 0 ] && [ -s '$W/meta.img' ]"
"$O/btrfs-image" -r "$W/meta.img" "$W/rebuilt.img" >"$W/out" 2>&1; rc=$?
t "btrfs-image -r: metadump restores" bash -c "[ $rc -eq 0 ]"
"$O/btrfs" inspect-internal dump-super "$W/rebuilt.img" >"$W/out" 2>&1
t "btrfs-image -r: restored image keeps the label" has '^label[[:space:]]+KATLABEL$'
"$O/btrfs" check --readonly "$W/rebuilt.img" >"$W/out" 2>&1; rc=$?
t "btrfs-image -r: restored image passes check" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"

# --- btrfs-convert: an ext4 image with known content ----------------------------------------------
CR=$W/croot; mkdir -p "$CR/d"
printf 'hello ext4\n' > "$CR/small.txt"
python3 -c 'import sys; sys.stdout.write("alpha beta gamma delta\n" * 3000)' > "$CR/d/big.txt"
ln -s d/big.txt "$CR/link"
EXT=$W/ext.img; truncate -s 128M "$EXT"
mke2fs -q -t ext4 -b 4096 -N 256 -L CONVLABEL -O ^metadata_csum,^uninit_bg,^has_journal -d "$CR" -F "$EXT" \
    >"$W/mke2fs.out" 2>&1 || { cat "$W/mke2fs.out"; failed=$((failed+1)); }
CSMALL_SHA=$(printf 'hello ext4\n' | sha256sum | cut -d' ' -f1)
cp "$EXT" "$W/ext-bad.img"; printf '\0\0' | dd of="$W/ext-bad.img" bs=1 seek=$((1024 + 56)) conv=notrunc status=none
"$O/btrfs-convert" --no-progress "$W/ext-bad.img" >"$W/out" 2>&1; rc=$?
t "convert: image without an ext superblock is rejected" bash -c "[ $rc -ne 0 ] && grep -q 'no file system found to convert' '$W/out'"
"$O/btrfs-convert" --no-progress -L "$EXT" >"$W/out" 2>&1; rc=$?
t "convert: ext4 image converts" bash -c "[ $rc -eq 0 ] && grep -q 'Conversion complete' '$W/out'"
"$O/btrfs" check --readonly "$EXT" >"$W/out" 2>&1; rc=$?
t "convert: converted fs passes check" bash -c "[ $rc -eq 0 ] && grep -q 'no error found' '$W/out'"
"$O/btrfs" inspect-internal dump-super "$EXT" >"$W/out" 2>&1
t "convert -L: label copied from ext4" has '^label[[:space:]]+CONVLABEL$'
mkdir "$W/conv-restored"
"$O/btrfs" restore -i "$EXT" "$W/conv-restored" >"$W/out" 2>&1
t "convert: small file content" bash -c "[ \"\$(sha256sum < '$W/conv-restored/small.txt' | cut -d' ' -f1)\" = '$CSMALL_SHA' ]"
t "convert: big file content" bash -c "[ \"\$(sha256sum < '$W/conv-restored/d/big.txt' | cut -d' ' -f1)\" = '$BIG_SHA' ]"
"$O/btrfs-convert" --no-progress -r "$EXT" >"$W/out" 2>&1; rc=$?
t "convert -r: rollback succeeds" bash -c "[ $rc -eq 0 ] && grep -q '^Rollback succeeded$' '$W/out'"
fsck.ext4 -fn "$EXT" >"$W/out" 2>&1; rc=$?
t "convert -r: rolled-back ext4 passes e2fsck" bash -c "[ $rc -eq 0 ]"

# --- upstream's own suite: tests/fsck-tests ------------------------------------------------------------
# Every case runs twice, as upstream's `make test-fsck` and `make test-fsck TEST_ENABLE_OVERRIDE=true` do: in
# the original mode, then with `--mode=lowmem` (common.local keeps repair in the original mode unless the case
# has a .lowmem_repairable beacon). tests/fsck-tests.sh itself is not called (its check_kernel_support runs
# `modprobe btrfs`); this loop does what its run_one_test does, on a scratch copy of each case (extract_image
# writes *.restored next to the image) in a subshell, so one _fail ends one case.
#  - A case dir with only images: tests/common's check_all_images runs the default check_image on each,
#    `btrfs check` must fail, `check --repair --force` must succeed and a re-check must pass.
#  - A case dir with its own test.sh: that script is run, as fsck-tests.sh does, except for the cases below.
#    Each of them needs root, a loop device, a mount or a kernel btrfs, none of which an unprivileged image
#    build has (setup_root_helper fails the case without sudo):
FSCK_ROOT_ONLY="
012-leaf-corruption           setup_root_helper; losetup a restored image and mount it to verify the repair
013-extent-tree-rebuild       prepare_test_dev + mkfs_test_dev + run_check_mount_test_dev (mounts and fills a fs)
024-clear-space-cache         mkfs_test_dev + run_check_mount_test_dev (mounts, writes, umounts)
025-file-extents              mkfs_test_dev + run_check_mount_test_dev (creates the extents through a mount)
028-unaligned-super-dev-sizes setup_root_helper + run_check_mount_test_dev (mounts the repaired image)
031-metadatadump-check-data-csum mkfs_test_dev + run_check_mount_test_dev (writes data through a mount)
033-lowmem-collission-dir-items mkfs_test_dev + run_check_mount_test_dev (creates the dir items through a mount)
037-freespacetree-repair      mkfs_test_dev + run_check_mount_test_dev (fills the free space tree through a mount)
052-init-csum-tree            prepare_test_dev + loop device + mount
056-raid56-false-alerts       setup_root_helper; mkfs on loop devices, mount
057-seed-false-alerts         setup_root_helper; mkfs on loop devices, mount, seeding
059-shrunk-device             setup_root_helper; root-only device resizing
060-degraded-check            setup_root_helper; mkfs on loop devices, then removes one
073-squota                    mkfs_test_dev + run_check_mount_test_dev (simple quota needs a mount)
074-raid56-read               setup_root_helper; mkfs on loop devices, mount
076-large-quota-tree          mkfs_test_dev + run_check_mount_test_dev (creates qgroups through a mount)
"
FT=$W/fsck-tests
fsck_case() { # fsck_case <case dir> <original|lowmem>
  local name work log
  name=$(basename "$1"); work="$FT/$2/$name"; log="$FT/$2-$name.log"
  mkdir -p "$FT/$2" && cp -a "$1" "$work" || return 1
  ( set +u +o pipefail
    export LANG=C TOP="$O" INTERNAL_BIN="$O" TEST_TOP="$SRC/tests" RESULTS="$log" TEST_MNT="$FT/mnt"
    if [ "$2" = lowmem ]; then export TEST_ENABLE_OVERRIDE=true TEST_ARGS_CHECK=--mode=lowmem
    else export TEST_ENABLE_OVERRIDE=false; fi
    cd "$work" || exit 1
    if [ -e test.sh ]; then bash ./test.sh
    else source "$TEST_TOP/common" && check_all_images; fi
  ) || { tail -n 15 "$log"; return 1; }
  # A case that ran no btrfs command (e.g. it found no image) would pass vacuously.
  [ "$(grep -c '^====== RUN ' "$log")" -gt 0 ] || { echo "no command run in $name"; return 1; }
}
nimg=0; nscript=0; nexcl=0
for d in "$SRC"/tests/fsck-tests/*/; do
  name=$(basename "$d")
  if [ -e "$d/test.sh" ]; then
    if printf '%s\n' "$FSCK_ROOT_ONLY" | grep -q "^$name "; then nexcl=$((nexcl+1)); continue; fi
    nscript=$((nscript+1))
  else nimg=$((nimg+1)); fi
  for flavor in original lowmem; do
    t "fsck-tests ($flavor): $name" fsck_case "${d%/}" "$flavor"
  done
done
# The exclusion list must name existing cases only, so that it cannot silently drift from upstream.
t "fsck-tests: every excluded case exists" bash -c "[ $nexcl -eq $(printf '%s\n' "$FSCK_ROOT_ONLY" | grep -c .) ]"
t "fsck-tests: image-only and test.sh cases found" bash -c "[ $nimg -gt 0 ] && [ $nscript -gt 0 ]"

# --- upstream's own suite: misc-tests/cli-tests that need no root ------------------------------------
# misc-tests/015 (dump-super on random data must not crash and must refuse without -F) and cli-tests/026
# (receive with a missing stream file must fail, also with --dump), run the way misc-tests.sh/cli-tests.sh
# run a case. The other misc/cli cases mount, use loop devices or call setup_root_helper.
other_case() { # other_case <case dir>
  local name log
  name=$(basename "$(dirname "$1")")-$(basename "$1"); log="$FT/$name.log"
  mkdir -p "$FT"
  ( set +u +o pipefail
    export LANG=C TOP="$O" INTERNAL_BIN="$O" TEST_TOP="$SRC/tests" RESULTS="$log" TEST_MNT="$FT/mnt"
    cd "$1" && bash ./test.sh
  ) || { tail -n 15 "$log"; return 1; }
  [ "$(grep -c '^====== RUN ' "$log")" -gt 0 ] || { echo "no command run in $name"; return 1; }
}
for c in misc-tests/015-dump-super-garbage cli-tests/026-receive-missing-stream; do
  [ -d "$SRC/tests/$c" ] || { t "upstream case $c exists" false; continue; }
  t "$c" other_case "$SRC/tests/$c"
done

# --- upstream CI's unit tests: `make test-api` and `./hash-vectest` (.github/workflows/devel.yml) --------
# Each API test binary prints its number of cases when run without arguments, then runs case N given N; the
# json cases must print valid JSON (upstream pipes them to jq). hash-vectest checks every checksum algorithm
# against known test vectors and fails on a mismatch.
api_suite() { # api_suite <binary> [json]
  local max n
  max=$("$O/$1") || return 1
  [ "$max" -gt 0 ] 2>/dev/null || { echo "$1 reported no cases: '$max'"; return 1; }
  for n in $(seq 1 "$max"); do
    if [ "${2:-}" = json ]; then
      "$O/$1" "$n" > "$W/api.out" || { echo "$1 $n failed"; return 1; }
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$W/api.out" || { echo "$1 $n: invalid JSON"; cat "$W/api.out"; return 1; }
    else
      "$O/$1" "$n" >/dev/null || { echo "$1 $n failed"; return 1; }
    fi
  done
}
t "test-api: json-formatter-test" api_suite json-formatter-test json
t "test-api: string-table-test" api_suite string-table-test
t "test-api: array-test" api_suite array-test
# hash-vectest prints "<algo> vector N: match|MISMATCH" and exits 0 either way, so its output is asserted:
# no mismatch, and every algorithm it tested matched at least one vector.
hash_vectest() {
  "$O/hash-vectest" > "$W/hash.out" 2>&1 || { cat "$W/hash.out"; return 1; }
  ! grep -q MISMATCH "$W/hash.out" || { grep -A2 MISMATCH "$W/hash.out"; return 1; }
  local algo n=0
  for algo in $(sed -n 's/^TEST: name=\([^ ]*\) .*/\1/p' "$W/hash.out"); do
    grep -q "^$algo vector [0-9]*: match$" "$W/hash.out" || { echo "no match for $algo"; return 1; }
    n=$((n+1))
  done
  [ "$n" -ge 4 ] || { echo "only $n algorithms tested"; cat "$W/hash.out"; return 1; }
}
t "hash-vectest: crc32c/xxhash64/sha256/blake2b vectors match" hash_vectest

emit_ctrf "btrfs-progs" "$passed" "$failed" 0
