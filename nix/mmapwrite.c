// SPDX-License-Identifier: GPL-2.0
/*
 * A large file written through mmap, for as long as it is asked for.
 *
 * This is the load the deployment's real jobs put on a mount: tens of large
 * files being written through a shared mapping at once, which is what keeps the
 * client deep in dirty throttling. A single small write/close/read-back on its
 * own never sees anything, because nothing is competing for the pages it needs.
 *
 *   mmapwrite <path> <bytes> <seconds>
 *
 * The mapping is written over and over until the deadline rather than once:
 * what matters is the rate pages are dirtied at, not how much of the file is
 * eventually on disk, so a bed that fits in the test's disk can still put the
 * client under the pressure the deployment has.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	const char *path;
	size_t size, off;
	double deadline;
	unsigned long rounds = 0;
	unsigned char byte = 'a';
	char *p;
	int fd;

	if (argc != 4) {
		fprintf(stderr, "usage: %s <path> <bytes> <seconds>\n", argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	deadline = now() + strtod(argv[3], NULL);
	if (!size) {
		fprintf(stderr, "bytes must be non-zero\n");
		return 2;
	}

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open");
		return 2;
	}
	if (ftruncate(fd, size) < 0) {
		perror("ftruncate");
		return 2;
	}
	p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 2;
	}

	while (now() < deadline) {
		/*
		 * Touching every page is the point: the fault and the dirty are
		 * what put pressure on everything else on the mount. A different
		 * byte per round keeps it from being a no-op the kernel can spot.
		 */
		for (off = 0; off < size; off += 4096)
			p[off] = byte;
		byte = (byte == 'z') ? 'a' : byte + 1;
		rounds++;
	}

	munmap(p, size);
	close(fd);
	printf("%s: %lu rounds of %zu bytes\n", path, rounds, size);
	return 0;
}
