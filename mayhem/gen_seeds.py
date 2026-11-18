#!/usr/bin/env python3
"""Writes the image-target seeds: a mode byte plus patch records {u16 block, u16 pos, u8 len, bytes}
(see mayhem/fuzz_main.c). Block 0 of the base image's non-zero block list is the superblock."""
import os
import struct

def rec(blk, pos, data):
    return struct.pack("<HHB", blk, pos, len(data)) + data

SB_GEN = rec(0, 0x48, b"\x07")            # superblock generation
SB_NUMDEVS = rec(0, 0x88, b"\x02")        # num_devices
SB_ROOT = rec(0, 0x50, b"\x00\x10\x50")   # root tree logical address
SB_NODESIZE = rec(0, 0x94, b"\x00\x40")   # nodesize
NODE_ITEM = rec(40, 0x65, b"\x01\x02\x03\x04\x05\x06\x07\x08")
NODE_NR = rec(41, 0x60, b"\x20")          # nritems of a tree block header
LEAF_DATA = rec(60, 0x7f0, b"\xff" * 16)

# btrfs_convert patches the ext4 base (mayhem/base_ext.sparse): block 0 holds the superblock at +1024, 1 the
# group descriptors, 3 the root directory, 33 and 34 the inode tables (256-byte inodes).
EXT_INODES = rec(0, 1024, b"\x00\x01")        # s_inodes_count
EXT_GDT = rec(1, 0, b"\x05")                  # group 0 block bitmap location
EXT_DIRENT = rec(3, 0x10, b"\x20")            # directory entry rec_len
EXT_ROOT_SIZE = rec(33, 0x104, b"\xff\xff\x00\x00")   # i_size_lo of the root inode
EXT_MODE = rec(34, 0x00, b"\x00\x00")        # i_mode of an inode
EXT_EXTENT = rec(34, 0x28, b"\x0a\xf3\x05")   # extent header magic/entries of an inode

seeds = {
    "btrfs_check": {"clean": b"\x00", "lowmem": b"\x01", "csum_qgroup": b"\x06", "sb_gen": b"\x00" + SB_GEN,
                    "lowmem_item": b"\x01" + NODE_ITEM, "node_nr": b"\x01" + NODE_NR,
                    "sb_root": b"\x00" + SB_ROOT, "lowmem_data": b"\x03" + LEAF_DATA,
                    "repair": b"\x10", "repair_lowmem": b"\x11", "repair_csum": b"\x30",
                    "repair_extent": b"\x50", "repair_both": b"\x70", "repair_node_nr": b"\x10" + NODE_NR,
                    "repair_item": b"\x50" + NODE_ITEM},
    "btrfs_inspect": {f"mode{m}": bytes([m]) for m in range(12)},
    "btrfs_restore": {"dry": b"\x01", "all": b"\x00", "xattr_meta_snap": b"\x1e", "dry_overwrite": b"\x21",
                      "dry_item": b"\x01" + NODE_ITEM, "real_leafdata": b"\x1e" + LEAF_DATA,
                      "sb_numdevs": b"\x01" + SB_NUMDEVS},
    "btrfs_rescue": {**{f"mode{m}": bytes([m]) for m in range(9)},
                     "super_sb_gen": b"\x01" + SB_GEN, "zero_log_root": b"\x02" + SB_ROOT,
                     "space_cache_item": b"\x06" + NODE_ITEM, "uuid_tree_node": b"\x04" + NODE_NR},
    "btrfs_convert": {"default": b"\x00", "flags_dinL": b"\x0f", "xxhash": b"\x10", "sha256_nodesize4k": b"\x60",
                      "blake2_no_fst": b"\xb0", "sb_inodes": b"\x00" + EXT_INODES, "gdt": b"\x00" + EXT_GDT,
                      "dirent": b"\x00" + EXT_DIRENT, "root_size": b"\x00" + EXT_ROOT_SIZE,
                      "inode_mode": b"\x00" + EXT_MODE, "inode_extent": b"\x00" + EXT_EXTENT},
}
here = os.path.dirname(os.path.abspath(__file__))
for target, files in seeds.items():
    d = os.path.join(here, target, "testsuite")
    os.makedirs(d, exist_ok=True)
    for name, data in files.items():
        open(os.path.join(d, name), "wb").write(data)
