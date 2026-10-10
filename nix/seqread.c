// SPDX-License-Identifier: GPL-2.0
/*
 * seqread - sequential whole-file reads, the two shapes the deployment's
 * read-side waste measurement is about (see doc/gotchas.md and the commit
 * that added bc_readahead_expand()/bc_pg_test_read()): small files read
 * whole with plain read(2), and large files read sequentially through mmap.
 *
 * Neither shape writes anything interesting on its own - a write arm already
 * exists in mmapwrite.c and the closeopen/randwr/sizeclobber tools. This is
 * only the read side, and it is deliberately boring: fill a file with a
 * pattern cheap to check without a checksum library (byte i is (i * 2654435761)
 * truncated to a byte - a cheap multiplicative hash, enough to catch a
 * dropped or duplicated range without a real hash function's cost per byte on
 * a near-1 GiB file), then read it back the way the mode says to and verify
 * every byte. Correctness is not really what this is for - that is what
 * randwr.c and sizeclobber.c already check for this path - but checking it
 * anyway costs nothing and catches an actual regression, not just a slower
 * one, if the alignment changes ever got a boundary wrong.
 *
 *   seqread write  <path> <bytes>                    # lay down the pattern
 *   seqread mmap   <path> <bytes> [madvise]           # read back through mmap
 *   seqread small  <path-prefix> <count> <bytes-each> [read-path-prefix]
 *
 * "small" both writes and reads, because the point of that arm is the
 * close-to-open shape of many small files - open, write once, fsync, close,
 * reopen, read once, close - not a large file already resident from a
 * previous run. Without [read-path-prefix] the read reopens the same path it
 * wrote, which a same-mount run can answer from this process's own
 * writeback-pending pages without ever reaching the data service; passing a
 * second mount's path there (the test suite's /mnt/self + /mnt/selfb
 * pattern) is what makes the read a real network round trip, the same
 * reason sizeclobber.c's padding mode takes a second path. "mmap" only
 * reads; pair it with a "write" of the same path first (on the writing
 * mount) the way the test suite does, so the read is never answered from the
 * writer's own cache.
 *
 * [madvise] on the mmap mode calls madvise(MADV_SEQUENTIAL) on the mapping
 * before touching it, which is the one-line, optional, app-side improvement
 * to mmap's own read-around heuristic mentioned alongside this change: with
 * it, mmap uses the same forward-only readahead algorithm read(2) does
 * instead of centering each miss on the faulting page.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned char pattern_byte(size_t offset)
{
	/* A cheap multiplicative hash (Knuth's constant), truncated to one
	 * byte: deterministic, fast per-byte, and not a run of a single
	 * repeated value a compressor or a stray zero-fill could agree with
	 * by accident. */
	uint32_t h = (uint32_t)offset * 2654435761u;

	return (unsigned char)(h >> 24);
}

static int write_all(int fd, const char *buf, size_t size)
{
	size_t off = 0;

	while (off < size) {
		ssize_t n = write(fd, buf + off, size - off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0) {
			errno = EIO;
			return -1;
		}
		off += n;
	}
	return 0;
}

static ssize_t read_all(int fd, char *buf, size_t size)
{
	size_t got = 0;

	while (got < size) {
		ssize_t n = read(fd, buf + got, size - got);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			break;
		got += n;
	}
	return (ssize_t)got;
}

/* Fill @buf with the pattern for file-offset range [base, base+size). */
static void fill_pattern(char *buf, size_t base, size_t size)
{
	size_t i;

	for (i = 0; i < size; i++)
		buf[i] = (char)pattern_byte(base + i);
}

/* First mismatching offset in [0, size), or (size_t)-1 if none. */
static size_t find_mismatch(const char *buf, size_t base, size_t size)
{
	size_t i;

	for (i = 0; i < size; i++)
		if ((unsigned char)buf[i] != pattern_byte(base + i))
			return i;
	return (size_t)-1;
}

static int do_write(const char *path, size_t size)
{
	char chunk[1 << 20];
	size_t off = 0, n;
	int fd;

	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open (write)");
		return 2;
	}
	while (off < size) {
		n = size - off < sizeof(chunk) ? size - off : sizeof(chunk);
		fill_pattern(chunk, off, n);
		if (write_all(fd, chunk, n) < 0) {
			perror("write");
			close(fd);
			return 2;
		}
		off += n;
	}
	if (close(fd) < 0) {
		perror("close");
		return 2;
	}
	printf("wrote %s: %zu bytes\n", path, size);
	return 0;
}

static int do_mmap(const char *path, size_t size, int use_madvise)
{
	int fd, ret = 0;
	char *p;
	size_t bad;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror("open (mmap read)");
		return 2;
	}
	p = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 2;
	}
	if (use_madvise && madvise(p, size, MADV_SEQUENTIAL) < 0) {
		perror("madvise");
		munmap(p, size);
		close(fd);
		return 2;
	}

	/*
	 * Touch every page, in order, one byte each - the fault is what
	 * matters, not the byte read here; the real verification is the pass
	 * below, over the whole mapping at once, which is cheaper than a
	 * volatile-style per-page check and just as able to see a wrong byte
	 * anywhere in the file.
	 */
	{
		volatile char sink = 0;
		size_t off;

		for (off = 0; off < size; off += 4096)
			sink += p[off];
		(void)sink;
	}

	bad = find_mismatch(p, 0, size);
	if (bad != (size_t)-1) {
		fprintf(stderr, "seqread mmap %s: byte %zu wrong: got 0x%02x want 0x%02x\n",
			path, bad, (unsigned char)p[bad], pattern_byte(bad));
		ret = 1;
	} else {
		printf("seqread mmap %s: %zu bytes OK%s\n", path, size,
		       use_madvise ? " (MADV_SEQUENTIAL)" : "");
	}

	munmap(p, size);
	close(fd);
	return ret;
}

static int do_small(const char *prefix, const char *read_prefix,
		    unsigned long count, size_t bytes_each)
{
	char *buf = malloc(bytes_each);
	char *rbuf = malloc(bytes_each);
	unsigned long i;
	int ret = 0;

	if (!buf || !rbuf) {
		fprintf(stderr, "out of memory\n");
		free(buf);
		free(rbuf);
		return 2;
	}

	for (i = 0; i < count; i++) {
		char path[4096], rpath[4096];
		int fd;
		ssize_t n;
		size_t bad;

		snprintf(path, sizeof(path), "%s.%lu", prefix, i);
		snprintf(rpath, sizeof(rpath), "%s.%lu", read_prefix, i);
		fill_pattern(buf, i * 1000003UL /* a large prime, so files
						  * do not all hash identically */,
			    bytes_each);

		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			perror("open (small write)");
			ret = 2;
			break;
		}
		if (write_all(fd, buf, bytes_each) < 0) {
			perror("write (small)");
			close(fd);
			ret = 2;
			break;
		}
		/*
		 * read_prefix may name a second mount of the same export (the
		 * test suite's /mnt/self + /mnt/selfb pattern): without this,
		 * the read below can be answered from this same process's own
		 * writeback-pending pages, through this same mount's cache,
		 * never reaching the data service at all - fsync is what
		 * close-to-open correctness on the *other* mount actually
		 * depends on, so this is not merely belt-and-suspenders.
		 */
		if (fsync(fd) < 0) {
			perror("fsync (small write)");
			close(fd);
			ret = 2;
			break;
		}
		if (close(fd) < 0) {
			perror("close (small write)");
			ret = 2;
			break;
		}

		fd = open(rpath, O_RDONLY);
		if (fd < 0) {
			perror("open (small read)");
			ret = 2;
			break;
		}
		n = read_all(fd, rbuf, bytes_each);
		close(fd);
		if (n < 0) {
			perror("read (small)");
			ret = 2;
			break;
		}
		if ((size_t)n != bytes_each) {
			fprintf(stderr, "seqread small %s: short read %zd of %zu\n",
				rpath, n, bytes_each);
			ret = 1;
			break;
		}
		bad = find_mismatch(rbuf, i * 1000003UL, bytes_each);
		if (bad != (size_t)-1) {
			fprintf(stderr, "seqread small %s: byte %zu wrong\n", rpath, bad);
			ret = 1;
			break;
		}
	}

	free(buf);
	free(rbuf);
	if (!ret)
		printf("seqread small %s.* (read via %s.*): %lu files x %zu bytes OK\n",
		       prefix, read_prefix, count, bytes_each);
	return ret;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		goto usage;

	if (!strcmp(argv[1], "write")) {
		if (argc != 4)
			goto usage;
		return do_write(argv[2], strtoul(argv[3], NULL, 0));
	}
	if (!strcmp(argv[1], "mmap")) {
		int use_madvise;

		if (argc < 4 || argc > 5)
			goto usage;
		use_madvise = argc == 5 && !strcmp(argv[4], "madvise");
		if (argc == 5 && !use_madvise) {
			fprintf(stderr, "seqread mmap: unknown option %s\n", argv[4]);
			return 2;
		}
		return do_mmap(argv[2], strtoul(argv[3], NULL, 0), use_madvise);
	}
	if (!strcmp(argv[1], "small")) {
		const char *read_prefix;

		if (argc < 5 || argc > 6)
			goto usage;
		read_prefix = argc == 6 ? argv[5] : argv[2];
		return do_small(argv[2], read_prefix, strtoul(argv[3], NULL, 0),
				strtoul(argv[4], NULL, 0));
	}

usage:
	fprintf(stderr,
		"usage: %s write <path> <bytes>\n"
		"       %s mmap  <path> <bytes> [madvise]\n"
		"       %s small <path-prefix> <count> <bytes-each> [read-path-prefix]\n",
		argv[0], argv[0], argv[0]);
	return 2;
}
