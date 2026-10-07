// SPDX-License-Identifier: GPL-2.0
/*
 * Close-to-open read-back, in one process and as tight as it will go.
 *
 * This is the shape an application uses - write, close, open, read - and the
 * one a shell loop cannot reach. A shell loop forks a process for the writer
 * and another for the reader, and the fork, exec and teardown between them are
 * far longer than the window this is looking for. Here there is a close() and
 * an open() and nothing else, so whatever an application would see, this sees
 * first.
 *
 *   closeopen <path> <bytes> <iterations> [unlink|fsync]
 *
 * The optional word picks a variation:
 *
 *   unlink   remove the file before each write, so every iteration writes a
 *            fresh inode rather than truncating the one before it. The
 *            difference matters: a stale cache is keyed on the inode, and an
 *            application writing a new side file each time gets the first
 *            case, not the second. Plain truncation is the default.
 *   fsync    fsync() before the close, for the question of whether a
 *            durability point makes the read-back correct. Nothing else here
 *            syncs: an application that has to fsync to read its own write
 *            back is the bug being looked for, not the fix.
 *
 * The conditions are counted separately, because they are different bugs:
 *
 *   size0     the fstat() after the open says the file is empty
 *   size_bad  the size is wrong, and not by being zero
 *   read0     the size looked right and the read hit end-of-file at once
 *   short     fewer bytes came back than the size said
 *   wrong     the right number of bytes, and not the bytes written
 *
 * Only the *first* read-back after each close is counted: that is what an
 * application does, and a second attempt would be measuring a different thing.
 * When the first is wrong it is retried anyway, only to report how long the
 * staleness lasted - the number that says whether an application can lose this
 * race or only a tight loop can. That retry is bounded and paced, so a
 * read-back that never clears is counted as stuck rather than spinning here.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define RETRY_LIMIT	2000	/* * 100us = 200ms before "stuck" */
#define RETRY_PACE_US	100

#define B_SIZE0		1
#define B_SIZE_BAD	2
#define B_READ0		4
#define B_SHORT		8
#define B_WRONG		16

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Write @size bytes from @buf, in full. Returns 0 or -1. */
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

/* Read up to @size bytes, to end of file. Returns the count, or -1. */
static ssize_t read_all(int fd, char *buf, size_t size)
{
	size_t off = 0;

	while (off < size) {
		ssize_t n = read(fd, buf + off, size - off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			break;
		off += n;
	}
	return off;
}

/*
 * One open/fstat/read/close. Returns 0 if the read-back was correct, else the
 * set of B_* bits that were wrong. Every condition is tested independently:
 * a stale size and an empty read are the same symptom to an application only
 * if you stop looking at where they come from.
 */
static int read_back(const char *path, const char *wbuf, char *rbuf,
		     size_t size)
{
	struct stat st;
	ssize_t n;
	int bad = 0;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		perror("open for read");
		exit(2);
	}
	if (fstat(fd, &st) < 0) {
		perror("fstat");
		exit(2);
	}
	n = read_all(fd, rbuf, size);
	close(fd);
	if (n < 0) {
		perror("read");
		exit(2);
	}

	if (st.st_size == 0)
		bad |= B_SIZE0;
	else if (st.st_size != (off_t)size)
		bad |= B_SIZE_BAD;

	if (n == 0)
		bad |= B_READ0;
	else if (n != (ssize_t)size)
		bad |= B_SHORT;
	else if (memcmp(wbuf, rbuf, size))
		bad |= B_WRONG;

	return bad;
}

int main(int argc, char **argv)
{
	const char *path;
	size_t size;
	unsigned long iters, i;
	unsigned long count[5] = { 0 };	/* indexed by bit position */
	unsigned long stuck = 0;
	double worst = 0;
	int variation = 0;
	char *wbuf, *rbuf;

	if (argc != 4 && argc != 5) {
		fprintf(stderr,
			"usage: %s <path> <bytes> <iterations> [unlink|fsync]\n",
			argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	iters = strtoul(argv[3], NULL, 0);
	if (argc == 5) {
		if (!strcmp(argv[4], "unlink"))
			variation = 1;
		else if (!strcmp(argv[4], "fsync"))
			variation = 2;
		else {
			fprintf(stderr, "unknown variation: %s\n", argv[4]);
			return 2;
		}
	}
	if (!size || !iters) {
		fprintf(stderr, "bytes and iterations must be non-zero\n");
		return 2;
	}

	wbuf = malloc(size);
	rbuf = malloc(size);
	if (!wbuf || !rbuf) {
		fprintf(stderr, "out of memory\n");
		return 2;
	}
	memset(wbuf, 'A', size);

	for (i = 0; i < iters; i++) {
		int bad, bit, fd;

		if (variation == 1 && unlink(path) && errno != ENOENT) {
			perror("unlink");
			return 2;
		}
		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			perror("open for write");
			return 2;
		}
		if (write_all(fd, wbuf, size) < 0) {
			perror("write");
			return 2;
		}
		if (variation == 2 && fsync(fd) < 0) {
			perror("fsync");
			return 2;
		}
		close(fd);

		bad = read_back(path, wbuf, rbuf, size);
		if (!bad)
			continue;

		for (bit = 0; bit < 5; bit++)
			if (bad & (1 << bit))
				count[bit]++;

		{
			double t0 = now();
			int tries;

			for (tries = 0; bad && tries < RETRY_LIMIT; tries++) {
				usleep(RETRY_PACE_US);
				bad = read_back(path, wbuf, rbuf, size);
			}
			if (bad) {
				stuck++;
			} else {
				double dt = now() - t0;

				if (dt > worst)
					worst = dt;
			}
		}
	}

	printf("iters=%lu size0=%lu size_bad=%lu read0=%lu short=%lu "
	       "wrong=%lu stuck=%lu worst_window_ms=%.3f\n",
	       iters, count[0], count[1], count[2], count[3], count[4],
	       stuck, worst * 1000);
	return 0;
}
