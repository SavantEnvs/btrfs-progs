/*
 * mayhem/fuzz_receive_decompress.c - libFuzzer target for the decompression fallback of
 * `btrfs receive` (cmds/receive.c: decompress_and_write -> decompress_zlib / decompress_zstd /
 * decompress_lzo / decompress_lzo_inline, then the pwrite of the unencoded range).
 *
 * In `btrfs receive` these run from process_encoded_write() for every BTRFS_SEND_C_ENCODED_WRITE
 * command of a send stream: when the BTRFS_IOC_ENCODED_WRITE ioctl fails with ENOSPC/ENOTTY/EINVAL,
 * or always with --force-decompress. Every argument comes straight from the stream's TLVs
 * (common/send-stream.c, BTRFS_SEND_C_ENCODED_WRITE) with no range check in between. That path needs
 * a mounted btrfs (do_receive: find_mount_root, BTRFS_IOC_INO_LOOKUP), so the file-input
 * btrfs_receive target can only reach `receive --dump`; this target includes receive.c to call the
 * static decompress_and_write() on the same arguments, with write_fd a memfd instead of the inode.
 *
 * Input layout (all little endian; the field widths bound the sizes, so the harness never asks
 * calloc() for more than 16 MiB, which a real stream could but which ASan reports as an allocation
 * error rather than returning NULL as glibc does):
 *   [0]      compression: BTRFS_ENCODED_IO_COMPRESSION_ZLIB + byte % 7 (zlib, zstd, lzo 4K..64K)
 *   [1..3]   unencoded_len       (BTRFS_SEND_A_UNENCODED_LEN)
 *   [4..6]   unencoded_file_len  (BTRFS_SEND_A_UNENCODED_FILE_LEN)
 *   [7..9]   unencoded_offset    (BTRFS_SEND_A_UNENCODED_OFFSET)
 *   [10..11] file offset         (BTRFS_SEND_A_FILE_OFFSET)
 *   [12..]   encoded data        (BTRFS_SEND_A_DATA)
 *
 * State: the memfd is created once and truncated to 0 before each input; the btrfs_receive context
 * (including the lazily created zlib/zstd streams) is fresh per input and freed after it, as
 * cmd_receive() does at its end.
 */
#include "../cmds/receive.c"

#include <sys/mman.h>

static int fuzz_fd = -1;

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	(void)argc; (void)argv;
	fuzz_fd = memfd_create("btrfs-receive-decompress", 0);
	if (fuzz_fd < 0)
		abort();
	return 0;
}

static u64 le24(const uint8_t *p)
{
	return (u64)p[0] | ((u64)p[1] << 8) | ((u64)p[2] << 16);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct btrfs_receive rctx;
	u32 compression;
	u64 unencoded_len, unencoded_file_len, unencoded_offset, offset;

	if (size < 12)
		return -1;
	if (fuzz_fd < 0)
		LLVMFuzzerInitialize(NULL, NULL);
	if (ftruncate(fuzz_fd, 0) != 0)
		abort();

	compression = BTRFS_ENCODED_IO_COMPRESSION_ZLIB + data[0] % 7;
	unencoded_len = le24(data + 1);
	unencoded_file_len = le24(data + 4);
	unencoded_offset = le24(data + 7);
	offset = (u64)data[10] | ((u64)data[11] << 8);

	memset(&rctx, 0, sizeof(rctx));
	rctx.mnt_fd = -1;
	rctx.dest_dir_fd = -1;
	rctx.write_fd = fuzz_fd;

	decompress_and_write(&rctx, (const char *)data + 12, offset, size - 12,
			     unencoded_file_len, unencoded_len, unencoded_offset,
			     compression);

#if COMPRESSION_ZSTD
	if (rctx.zstd_dstream)
		ZSTD_freeDStream(rctx.zstd_dstream);
#endif
	if (rctx.zlib_stream) {
		inflateEnd(rctx.zlib_stream);
		free(rctx.zlib_stream);
	}
	return 0;
}
