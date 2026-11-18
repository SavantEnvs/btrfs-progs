/*
 * Fuzz wrapper for the btrfs CLI. This object provides main(); btrfs.c is compiled with
 * -Dmain=btrfs_original_main, so the real command dispatcher and every command run unmodified.
 *
 * A btrfs image is at least 16 MiB and every tree block and the superblock are crc32c-checked, so a
 * raw image is unfuzzable. For the image targets the input is instead a tiny patch list applied to an
 * embedded base image (mayhem/base.sparse); the checksums of all tree blocks and the superblock are
 * then recomputed, so mutations reach the parsers instead of dying in the csum check.
 *
 *   image targets:   byte 0 selects the command variant, then records
 *                    { u16 block, u16 pos, u8 len, len bytes } patching the block-th non-zero 4 KiB
 *                    block of the base image at pos.
 *   convert target:  the same patch list, applied to an embedded ext4 image (mayhem/base_ext.sparse,
 *                    no metadata checksums, so nothing to recompute); byte 0 selects btrfs-convert options.
 *   receive target:  the input is a btrfs send stream; command crc32c values are recomputed.
 *   rescue target:   the same patch list; byte 0 selects the `btrfs rescue` subcommand. check's mode byte also
 *                    selects --repair / --init-csum-tree / --init-extent-tree (bits 16/32/64).
 *
 * The CLI is run on /proc/self/fd/N of an anonymous memfd, so nothing touches the disk.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "crypto/crc32c.h"

#define T_CHECK 1
#define T_INSPECT 2
#define T_RESTORE 3
#define T_RECEIVE 4
#define T_IMAGE 5
#define T_CONVERT 6
#define T_RESCUE 7

#ifndef FUZZ_TARGET
#error "define FUZZ_TARGET"
#endif

#define NODESIZE 16384u
#define SB_OFFSET 65536u
#define SB_SIZE 4096u
#define CSUM_SIZE 32u
#define HDR_FSID 0x20u

#if FUZZ_TARGET == T_IMAGE
extern int image_original_main(int argc, char **argv);
#define ORIGINAL_MAIN image_original_main
#elif FUZZ_TARGET == T_CONVERT
extern int convert_original_main(int argc, char **argv);
#define ORIGINAL_MAIN convert_original_main
#else
extern int btrfs_original_main(int argc, char **argv);
#define ORIGINAL_MAIN btrfs_original_main
#endif

__asm__(".section .rodata\n"
	".balign 16\n"
	"mayhem_base_sparse:\n"
	".incbin \"" BASE_SPARSE_PATH "\"\n"
	"mayhem_base_sparse_end:\n"
	".previous\n");
extern const uint8_t mayhem_base_sparse[], mayhem_base_sparse_end[];

#define SPARSE_REC (4u + 4096u)

static uint32_t rd32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put_csum(uint8_t *dst, const uint8_t *data, size_t len)
{
	uint32_t c = ~crc32c_le(~0u, data, len);

	memset(dst, 0, CSUM_SIZE);
	dst[0] = c;
	dst[1] = c >> 8;
	dst[2] = c >> 16;
	dst[3] = c >> 24;
}

#if FUZZ_TARGET != T_CONVERT
static void fix_csums(uint8_t *img, uint32_t img_size)
{
	uint8_t fsid[16];

	memcpy(fsid, img + SB_OFFSET + HDR_FSID, 16);
	put_csum(img + SB_OFFSET, img + SB_OFFSET + CSUM_SIZE, SB_SIZE - CSUM_SIZE);
	for (uint32_t o = 0; o + NODESIZE <= img_size; o += NODESIZE) {
		if (o == SB_OFFSET)
			continue;
		if (memcmp(img + o + HDR_FSID, fsid, 16) == 0)
			put_csum(img + o, img + o + CSUM_SIZE, NODESIZE - CSUM_SIZE);
	}
}
#endif

/* An environment failure must be loud: returning quietly would make every input a no-op with 0 coverage. */
static void die(const char *what)
{
	fprintf(stderr, "harness: %s failed: %s\n", what, strerror(errno));
	abort();
}

static int make_memfd(const char *name)
{
	int fd = memfd_create(name, 0);

	if (fd < 0) {
		char tmpl[] = "/tmp/btrfsfuzzXXXXXX";

		fd = mkstemp(tmpl);
		if (fd >= 0)
			unlink(tmpl);
	}
	return fd;
}

static void silence_stdout(void)
{
	int sink;

	if (getenv("BTRFS_FUZZ_VERBOSE"))
		return;
	sink = make_memfd("btrfs.stdout");
	if (sink >= 0) {
		dup2(sink, 1);
		close(sink);
	}
}

static int build_image(const uint8_t *patches, size_t plen)
{
	const uint8_t *base = mayhem_base_sparse + 4;
	size_t nrec = (mayhem_base_sparse_end - base) / SPARSE_REC;
	uint32_t img_size = rd32(mayhem_base_sparse) * 4096;
	int fd = make_memfd("btrfs.img");
	uint8_t *img;

	if (fd < 0 || ftruncate(fd, img_size) != 0)
		return -1;
	img = mmap(NULL, img_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (img == MAP_FAILED)
		return -1;
	for (size_t i = 0; i < nrec; i++) {
		const uint8_t *r = base + i * SPARSE_REC;

		memcpy(img + (size_t)rd32(r) * 4096, r + 4, 4096);
	}
	while (plen >= 5) {
		size_t blk = (patches[0] | patches[1] << 8) % nrec;
		size_t pos = (patches[2] | patches[3] << 8) % 4096;
		size_t len = patches[4];
		const uint8_t *r = base + blk * SPARSE_REC;

		patches += 5;
		plen -= 5;
		if (len > plen)
			len = plen;
		if (len > 4096 - pos)
			len = 4096 - pos;
		memcpy(img + (size_t)rd32(r) * 4096 + pos, patches, len);
		patches += len;
		plen -= len;
	}
#if FUZZ_TARGET != T_CONVERT
	fix_csums(img, img_size);
#endif
	munmap(img, img_size);
	return fd;
}

static int build_stream(const uint8_t *in, size_t n)
{
	int fd = make_memfd("btrfs.stream");
	uint8_t *buf;
	size_t p = 17;

	if (fd < 0)
		return -1;
	buf = malloc(n ? n : 1);
	if (!buf)
		return -1;
	memcpy(buf, in, n);
	while (p + 10 <= n) {
		uint32_t len = rd32(buf + p);
		uint32_t c;

		if (len > n - p - 10)
			break;
		memset(buf + p + 6, 0, 4);
		c = crc32c_le(0, buf + p, 10 + len);
		memcpy(buf + p + 6, &c, 4);
		p += 10 + len;
	}
	if (write(fd, buf, n) != (ssize_t)n)
		return -1;
	free(buf);
	return fd;
}

#if FUZZ_TARGET == T_RESTORE
/*
 * Scratch for `btrfs restore`: $TMPDIR/btrfsfuzz-restore.<pid>, unique per process, so concurrent executors
 * never touch each other's tree. The process removes it at exit; a crash leaves it, and the next input's
 * process sweeps the trees of dead pids (kill(pid, 0) == ESRCH) before creating its own.
 *
 * restore builds output paths from the image's dir item names without rejecting '/' or "..", so a mutated
 * name can climb out of the destination. The destination is therefore RESTORE_DEPTH directories below the
 * scratch root: one name is at most 255 bytes, i.e. at most 85 "..", which cannot leave the root. -S
 * (symlink restore) is not passed, since a symlink restored first could redirect later writes anywhere.
 */
#define RESTORE_PREFIX "btrfsfuzz-restore."
#define RESTORE_DEPTH 100

static char restore_root[PATH_MAX];
static char restore_dest[PATH_MAX];

/* restore -m applies the image's modes, so a directory may be unreadable: make it enterable before descending. */
static void remove_tree_at(int dirfd, const char *name)
{
	struct stat st;
	struct dirent *e;
	DIR *d;
	int fd;

	if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(st.st_mode)) {
		unlinkat(dirfd, name, 0);
		return;
	}
	(void)!fchmodat(dirfd, name, 0700, 0);
	fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
	if (fd < 0)
		return;
	d = fdopendir(fd);
	if (!d) {
		close(fd);
		return;
	}
	while ((e = readdir(d)))
		if (strcmp(e->d_name, ".") && strcmp(e->d_name, ".."))
			remove_tree_at(fd, e->d_name);
	closedir(d);
	unlinkat(dirfd, name, AT_REMOVEDIR);
}

static void remove_tree(const char *path)
{
	remove_tree_at(AT_FDCWD, path);
}

static void cleanup_restore_dir(void)
{
	remove_tree(restore_root);
}

static void restore_setup(void)
{
	const char *tmp = getenv("TMPDIR");
	size_t plen = strlen(RESTORE_PREFIX);
	struct dirent *e;
	size_t len;
	DIR *d;

	if (!tmp || !*tmp)
		tmp = "/tmp";
	d = opendir(tmp);
	if (!d)
		die("opendir($TMPDIR)");
	while ((e = readdir(d))) {
		char path[PATH_MAX], *end;
		long pid;

		if (strncmp(e->d_name, RESTORE_PREFIX, plen))
			continue;
		pid = strtol(e->d_name + plen, &end, 10);
		if (*end || pid <= 0 || pid == getpid() || kill(pid, 0) != -1 || errno != ESRCH)
			continue;
		if (snprintf(path, sizeof(path), "%s/%s", tmp, e->d_name) < (int)sizeof(path))
			remove_tree(path);
	}
	closedir(d);

	len = snprintf(restore_root, sizeof(restore_root), "%s/%s%d", tmp, RESTORE_PREFIX, getpid());
	if (len + 2 * RESTORE_DEPTH + 1 >= sizeof(restore_dest))
		die("TMPDIR path length");
	remove_tree(restore_root);
	if (mkdir(restore_root, 0700))
		die("mkdir(scratch root)");
	atexit(cleanup_restore_dir);
	memcpy(restore_dest, restore_root, len + 1);
	for (int i = 0; i < RESTORE_DEPTH; i++) {
		memcpy(restore_dest + len, "/d", 3);
		len += 2;
		if (mkdir(restore_dest, 0700))
			die("mkdir(scratch destination)");
	}
}
#endif

static char devpath[64];

int main(int argc, char **argv)
{
	FILE *f;
	uint8_t *in = NULL;
	size_t n = 0, cap = 0, r;
	uint8_t mode = 0;
	int fd;
	char *args[16];
	int na = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <input>\n", argv[0]);
		return 2;
	}
#if FUZZ_TARGET == T_IMAGE
	fd = make_memfd("btrfs.restored");
	if (fd < 0)
		die("memfd for the restored image");
	snprintf(devpath, sizeof(devpath), "/proc/self/fd/%d", fd);
	args[na++] = (char *)"btrfs-image";
	args[na++] = (char *)"-r";
	args[na++] = argv[1];
	args[na++] = devpath;
	args[na] = NULL;
	silence_stdout();
	return ORIGINAL_MAIN(na, args);
#endif
	f = fopen(argv[1], "rb");
	if (!f)
		die("opening the input");
	do {
		if (n == cap) {
			cap = cap ? cap * 2 : 4096;
			in = realloc(in, cap);
		}
		r = fread(in + n, 1, cap - n, f);
		n += r;
	} while (r > 0 && n < (1u << 20));
	fclose(f);

	if (FUZZ_TARGET != T_RECEIVE) {
		if (n < 1)
			return 0;
		mode = in[0];
		fd = build_image(in + 1, n - 1);
	} else {
		if (n < 17)
			return 0;
		fd = build_stream(in, n);
	}
	if (fd < 0)
		die("building the image");
	snprintf(devpath, sizeof(devpath), "/proc/self/fd/%d", fd);

	/* ask_user() prompts (repair of a fs with a log tree, rescue) must see EOF, never wait on a terminal. */
	if (freopen("/dev/null", "r", stdin) == NULL)
		die("reopening stdin");

#if FUZZ_TARGET == T_CONVERT
	args[na++] = (char *)"btrfs-convert";
#else
	args[na++] = (char *)"btrfs";
#endif
#if FUZZ_TARGET == T_CHECK
	args[na++] = (char *)"check";
	if (mode & 16) {
		args[na++] = (char *)"--repair";
		args[na++] = (char *)"--force";
		if (mode & 32)
			args[na++] = (char *)"--init-csum-tree";
		if (mode & 64)
			args[na++] = (char *)"--init-extent-tree";
	} else {
		args[na++] = (char *)"--readonly";
	}
	if (mode & 1)
		args[na++] = (char *)"--mode=lowmem";
	if (mode & 2)
		args[na++] = (char *)"--check-data-csum";
	if (mode & 4)
		args[na++] = (char *)"--qgroup-report";
	if (mode & 8) {
		args[na++] = (char *)"-s";
		args[na++] = (char *)"1";
	}
	args[na++] = devpath;
#elif FUZZ_TARGET == T_INSPECT
	static const char *const variants[][6] = {
		{"dump-tree", NULL},
		{"dump-tree", "-d", NULL},
		{"dump-tree", "-t", "extent", NULL},
		{"dump-tree", "-b", "5472256", "--follow", NULL},
		{"dump-tree", "-t", "csum", "--csum-items", NULL},
		{"dump-tree", "-u", NULL},
		{"dump-super", "-f", "-a", NULL},
		{"tree-stats", NULL},
		{"dump-tree", "-r", NULL},
		{"dump-tree", "-R", NULL},
		{"dump-tree", "-t", "fs", "--hide-names", "--dfs", NULL},
		{"dump-tree", "-t", "quota", "--csum-headers", NULL},
	};
	const char *const *v = variants[mode % 12];

	args[na++] = (char *)"inspect-internal";
	while (*v)
		args[na++] = (char *)*v++;
	args[na++] = devpath;
#elif FUZZ_TARGET == T_RESTORE
	restore_setup();
	args[na++] = (char *)"restore";
	args[na++] = (char *)"-i";
	args[na++] = (char *)"-v";
	if (mode & 1)
		args[na++] = (char *)"-D";
	if (mode & 2)
		args[na++] = (char *)"-x";
	if (mode & 4)
		args[na++] = (char *)"-m";
	if (mode & 16)
		args[na++] = (char *)"-s";
	if (mode & 32)
		args[na++] = (char *)"-o";
	args[na++] = devpath;
	args[na++] = restore_dest;
#elif FUZZ_TARGET == T_CONVERT
	static const char *const csums[] = { "crc32c", "xxhash", "sha256", "blake2" };

	args[na++] = (char *)"--no-progress";
	if (mode & 1)
		args[na++] = (char *)"-d";
	if (mode & 2)
		args[na++] = (char *)"-i";
	if (mode & 4)
		args[na++] = (char *)"-n";
	if (mode & 8)
		args[na++] = (char *)"-L";
	args[na++] = (char *)"--csum";
	args[na++] = (char *)csums[(mode >> 4) & 3];
	if (mode & 64) {
		args[na++] = (char *)"-N";
		args[na++] = (char *)"4096";
	}
	if (mode & 128) {
		args[na++] = (char *)"-O";
		args[na++] = (char *)"^free-space-tree";
	}
	args[na++] = devpath;
#elif FUZZ_TARGET == T_RESCUE
	static const char *const variants[][5] = {
		{"chunk-recover", "-y", NULL},
		{"super-recover", "-y", NULL},
		{"zero-log", NULL},
		{"fix-device-size", NULL},
		{"clear-uuid-tree", NULL},
		{"clear-ino-cache", NULL},
		{"clear-space-cache", "v1", NULL},
		{"clear-space-cache", "v2", NULL},
		{"fix-data-checksum", "-r", NULL},
	};
	const char *const *v = variants[mode % 9];

	args[na++] = (char *)"rescue";
	while (*v)
		args[na++] = (char *)*v++;
	args[na++] = devpath;
#elif FUZZ_TARGET == T_RECEIVE
	args[na++] = (char *)"receive";
	args[na++] = (char *)"--dump";
	args[na++] = (char *)"-f";
	args[na++] = devpath;
#endif
	args[na] = NULL;

	silence_stdout();
	return ORIGINAL_MAIN(na, args);
}
