#!/usr/bin/env python3
"""Writes the btrfs_receive_decompress seeds: one encoded write per compression type, laid out as
mayhem/fuzz_receive_decompress.c reads it (byte 0 compression, 3+3+3 bytes unencoded_len/file_len/offset,
2 bytes file offset, then the encoded data as btrfs stores it). zstd and lzo come from the system
libzstd/liblzo2 through ctypes (run where liblzo2-dev/libzstd-dev are installed, e.g. the commit image).

Usage: gen_decompress_seeds.py <outdir>
"""
import ctypes
import os
import struct
import sys
import zlib

ZLIB, ZSTD, LZO_4K = 1, 2, 3


def seed(comp, unencoded_len, file_len, unenc_off, offset, data):
    le24 = lambda v: struct.pack('<I', v)[:3]
    return bytes([comp - ZLIB]) + le24(unencoded_len) + le24(file_len) + le24(unenc_off) + \
        struct.pack('<H', offset) + data


def zstd(data):
    lib = ctypes.CDLL('libzstd.so.1')
    lib.ZSTD_compressBound.restype = ctypes.c_size_t
    lib.ZSTD_compress.restype = ctypes.c_size_t
    cap = lib.ZSTD_compressBound(ctypes.c_size_t(len(data)))
    out = ctypes.create_string_buffer(cap)
    n = lib.ZSTD_compress(out, ctypes.c_size_t(cap), data, ctypes.c_size_t(len(data)), 3)
    return out.raw[:n]


def lzo1x(data):
    lib = ctypes.CDLL('liblzo2.so.2')
    out = ctypes.create_string_buffer(len(data) + len(data) // 16 + 64 + 3)
    out_len = ctypes.c_ulong(0)
    wrk = ctypes.create_string_buffer(16384 * ctypes.sizeof(ctypes.c_void_p))
    rc = lib.lzo1x_1_compress(data, ctypes.c_ulong(len(data)), out, ctypes.byref(out_len), wrk)
    assert rc == 0, rc
    return out.raw[:out_len.value]


def lzo_extent(data, sector):
    """btrfs lzo extent: le32 total length, then per sector of input a le32 segment length and its
    lzo1x data; a segment header never crosses a sector boundary (zero padding instead)."""
    buf = bytearray(4)
    for i in range(0, len(data), sector):
        seg = lzo1x(data[i:i + sector])
        if sector - len(buf) % sector < 4:
            buf += bytes(sector - len(buf) % sector)
        buf += struct.pack('<I', len(seg)) + seg
    buf[0:4] = struct.pack('<I', len(buf))
    if len(buf) % sector:
        buf += bytes(sector - len(buf) % sector)
    return bytes(buf)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    small = b'hello btrfs receive\n' * 8
    big = b''.join(b'line %05d of an encoded write\n' % i for i in range(1200))[:32768]
    seeds = {
        'zlib-small': seed(ZLIB, len(small), len(small), 0, 0, zlib.compress(small)),
        'zlib-big-offset': seed(ZLIB, len(big), 8192, 4096, 4096, zlib.compress(big)),
        'zstd-small': seed(ZSTD, len(small), len(small), 0, 0, zstd(small)),
        'zstd-big': seed(ZSTD, len(big), len(big), 0, 0, zstd(big)),
    }
    # Inline lzo extent: one segment, no padding, shorter than a sector.
    seg = lzo1x(small)
    seeds['lzo4k-inline'] = seed(LZO_4K, len(small), len(small), 0, 0,
                                 struct.pack('<II', 8 + len(seg), len(seg)) + seg)
    for k, sector in enumerate((4096, 8192, 16384, 32768)):
        seeds['lzo%dk-extent' % (sector // 1024)] = seed(LZO_4K + k, len(big), len(big), 0, 0,
                                                         lzo_extent(big, sector))
    for name, data in seeds.items():
        with open(os.path.join(out, name), 'wb') as f:
            f.write(data)


if __name__ == '__main__':
    main()
