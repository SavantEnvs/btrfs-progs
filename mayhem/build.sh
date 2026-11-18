#!/usr/bin/env bash
#
# mayhem/build.sh — builds, in the commit image (as `mayhem`, in /mayhem):
#   1. the project's NORMAL-flags binaries (the test oracle) into /mayhem/mayhem/oracle/
#   2. the sanitized fuzz binaries /mayhem/btrfs_{check,inspect,restore,receive,image,convert,rescue} (wrapper main from
#      mayhem/fuzz_main.c over the real btrfs command objects; each binary is its own reproducer), and the
#      libFuzzer target /mayhem/btrfs_receive_decompress (+ -standalone) over receive's decompression fallback
# Air-gapped and re-runnable: only the in-image autotools and apt -dev packages are used.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem

# autoconf/automake are in the base image; the generated files are gitignored.
./autogen.sh >/dev/null
./configure --disable-documentation --disable-python --enable-convert --disable-backtrace \
    --disable-shared >/dev/null

# 1) Oracle: the project's normal flags (NO sanitizers, no fuzzer instrumentation), kept for mayhem/test.sh.
make clean >/dev/null 2>&1 || true
#    Also upstream CI's unit tests (`make test-api`, `make hash-vectest`): the json, string-table and
#    dynamic-array API tests and the checksum test vectors.
ORACLE_BINS="btrfs mkfs.btrfs btrfs-image btrfs-convert json-formatter-test string-table-test array-test hash-vectest"
make -j"$MAYHEM_JOBS" $ORACLE_BINS EXTRA_CFLAGS="$COVERAGE_FLAGS" EXTRA_LDFLAGS="$COVERAGE_FLAGS" >/dev/null
mkdir -p "$SRC/mayhem/oracle"
cp $ORACLE_BINS "$SRC/mayhem/oracle/"

# 2) Fuzz binaries: the project compiled with the sanitizers, DWARF 3 and SanCov instrumentation
#    (fuzzer-no-link: coverage guards without a libFuzzer main), btrfs.c's main renamed so that the
#    wrapper's main drives it, and LSan switched off at build time.
make clean >/dev/null 2>&1 || true
# -fsanitize=function is relaxed (and only that check): btrfs-progs calls rb-tree and list_sort callbacks
# through a generic function-pointer type on every run (common/rbtree-utils.c), which would halt every input.
SAN_FLAGS="$SANITIZER_FLAGS"
case "$SAN_FLAGS" in *-fsanitize=*undefined*) SAN_FLAGS="$SAN_FLAGS -fno-sanitize=function" ;; esac
FUZZ_FLAGS="$SAN_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem/lsan_off.o"
make -j"$MAYHEM_JOBS" -f Makefile -f mayhem/harness.mk fuzz-bins \
    EXTRA_CFLAGS="$FUZZ_FLAGS" EXTRA_LDFLAGS="$FUZZ_FLAGS" \
    btrfs_cflags=-Dmain=btrfs_original_main image_main_cflags=-Dmain=image_original_main \
    convert_main_cflags=-Dmain=convert_original_main \
    FUZZ_OUT="$OUT" FUZZ_LSAN_OFF="$SRC/mayhem/lsan_off.o" \
    FUZZ_ENGINE="$LIB_FUZZING_ENGINE" FUZZ_STANDALONE_MAIN="$STANDALONE_FUZZ_MAIN" >/dev/null
