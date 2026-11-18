#!/usr/bin/env python3
"""Writes btrfs send streams (v1/v2) by hand: the btrfs_receive seeds and the receive --dump oracle input.

Usage: gen_stream.py <name> <outfile>   (name: basic | snapshot | v2)
"""
import struct
import sys

A = dict(UUID=1, CTRANSID=2, INO=3, SIZE=4, MODE=5, UID=6, GID=7, RDEV=8, CTIME=9, MTIME=10, ATIME=11,
         OTIME=12, XATTR_NAME=13, XATTR_DATA=14, PATH=15, PATH_TO=16, PATH_LINK=17, FILE_OFFSET=18,
         DATA=19, CLONE_UUID=20, CLONE_CTRANSID=21, CLONE_PATH=22, CLONE_OFFSET=23, CLONE_LEN=24,
         FALLOCATE_MODE=25, FILEATTR=26, UNENCODED_FILE_LEN=27, UNENCODED_LEN=28, UNENCODED_OFFSET=29,
         COMPRESSION=30, ENCRYPTION=31)
C = dict(SUBVOL=1, SNAPSHOT=2, MKFILE=3, MKDIR=4, MKNOD=5, MKFIFO=6, MKSOCK=7, SYMLINK=8, RENAME=9,
         LINK=10, UNLINK=11, RMDIR=12, SET_XATTR=13, REMOVE_XATTR=14, WRITE=15, CLONE=16, TRUNCATE=17,
         CHMOD=18, CHOWN=19, UTIMES=20, END=21, UPDATE_EXTENT=22, FALLOCATE=23, FILEATTR=24,
         ENCODED_WRITE=25)

UUID1 = bytes(range(1, 17))
UUID2 = bytes(range(101, 117))


def crc32c(data, crc=0):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc


def u64(v):
    return struct.pack("<Q", v)


def ts(sec):
    return struct.pack("<QI", sec, 0)


def tlv(attr, val):
    return struct.pack("<HH", A[attr], len(val)) + val


def cmd(name, *attrs, last_data=None):
    body = b"".join(attrs)
    if last_data is not None:
        body += struct.pack("<H", A["DATA"]) + last_data
    hdr = struct.pack("<IHI", len(body), C[name], 0)
    crc = crc32c(hdr + body)
    return struct.pack("<IHI", len(body), C[name], crc) + body


def path(p):
    return tlv("PATH", p.encode())


def stream(version, cmds):
    return b"btrfs-stream\0" + struct.pack("<I", version) + b"".join(cmds)


def basic():
    text = b"hello btrfs receive\n" * 8
    return stream(1, [
        cmd("SUBVOL", path("snap1"), tlv("UUID", UUID1), tlv("CTRANSID", u64(7))),
        cmd("MKDIR", path("o257-7-0"), tlv("INO", u64(257))),
        cmd("RENAME", path("o257-7-0"), tlv("PATH_TO", b"dir")),
        cmd("MKFILE", path("o258-7-0"), tlv("INO", u64(258))),
        cmd("RENAME", path("o258-7-0"), tlv("PATH_TO", b"dir/file.txt")),
        cmd("WRITE", path("dir/file.txt"), tlv("FILE_OFFSET", u64(0)), tlv("DATA", text)),
        cmd("TRUNCATE", path("dir/file.txt"), tlv("SIZE", u64(160))),
        cmd("SET_XATTR", path("dir/file.txt"), tlv("XATTR_NAME", b"user.k"), tlv("XATTR_DATA", b"val")),
        cmd("CHMOD", path("dir/file.txt"), tlv("MODE", u64(0o640))),
        cmd("CHOWN", path("dir/file.txt"), tlv("UID", u64(1000)), tlv("GID", u64(100))),
        cmd("SYMLINK", path("dir/sym"), tlv("INO", u64(259)), tlv("PATH_LINK", b"file.txt")),
        cmd("LINK", path("dir/hard"), tlv("PATH_LINK", b"dir/file.txt")),
        cmd("MKFIFO", path("fifo"), tlv("INO", u64(260))),
        cmd("MKNOD", path("node"), tlv("INO", u64(261)), tlv("MODE", u64(0o20644)), tlv("RDEV", u64(0x105))),
        cmd("CLONE", path("dir/file.txt"), tlv("FILE_OFFSET", u64(0)), tlv("CLONE_LEN", u64(64)),
            tlv("CLONE_UUID", UUID1), tlv("CLONE_CTRANSID", u64(7)), tlv("CLONE_PATH", b"dir/file.txt"),
            tlv("CLONE_OFFSET", u64(64))),
        cmd("UPDATE_EXTENT", path("dir/file.txt"), tlv("FILE_OFFSET", u64(0)), tlv("SIZE", u64(4096))),
        cmd("REMOVE_XATTR", path("dir/file.txt"), tlv("XATTR_NAME", b"user.k")),
        cmd("UNLINK", path("dir/hard")),
        cmd("UTIMES", path("dir/file.txt"), tlv("ATIME", ts(1700000000)), tlv("MTIME", ts(1700000001)),
            tlv("CTIME", ts(1700000002))),
        cmd("END"),
    ])


def snapshot():
    return stream(1, [
        cmd("SNAPSHOT", path("snap2"), tlv("UUID", UUID2), tlv("CTRANSID", u64(9)),
            tlv("CLONE_UUID", UUID1), tlv("CLONE_CTRANSID", u64(7))),
        cmd("MKFILE", path("o300-9-0"), tlv("INO", u64(300))),
        cmd("RENAME", path("o300-9-0"), tlv("PATH_TO", b"new")),
        cmd("RMDIR", path("dir")),
        cmd("MKSOCK", path("sock"), tlv("INO", u64(301))),
        cmd("END"),
    ])


def v2():
    return stream(2, [
        cmd("SUBVOL", path("snap3"), tlv("UUID", UUID1), tlv("CTRANSID", u64(5))),
        cmd("MKFILE", path("o257-5-0"), tlv("INO", u64(257))),
        cmd("FALLOCATE", path("o257-5-0"), tlv("FALLOCATE_MODE", struct.pack("<I", 0)), tlv("FILE_OFFSET", u64(0)),
            tlv("SIZE", u64(8192))),
        cmd("FILEATTR", path("o257-5-0"), tlv("FILEATTR", u64(0x10))),
        cmd("WRITE", path("o257-5-0"), tlv("FILE_OFFSET", u64(0)), last_data=b"v2 stream data\n" * 4),
        cmd("ENCODED_WRITE", path("o257-5-0"), tlv("FILE_OFFSET", u64(0)), tlv("UNENCODED_FILE_LEN", u64(4096)),
            tlv("UNENCODED_LEN", u64(4096)), tlv("UNENCODED_OFFSET", u64(0)), tlv("COMPRESSION", struct.pack("<I", 1)),
            tlv("ENCRYPTION", struct.pack("<I", 0)), last_data=b"\x78\x9c" + b"\0" * 30),
        cmd("END"),
    ])


if __name__ == "__main__":
    data = {"basic": basic, "snapshot": snapshot, "v2": v2}[sys.argv[1]]()
    open(sys.argv[2], "wb").write(data)
