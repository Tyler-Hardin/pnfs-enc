/*
 * randwr - seeded random write/read/truncate exerciser with verification.
 *
 * A filesystem's encoded-write path only cares about the shapes that sit on a
 * boundary: a length that ends one byte into the next unit, an offset that is
 * not a page, a write that lands on top of what an earlier write left, a unit
 * small enough that the codec's frame is tiny. Hand-written arms fix three or
 * four of those and miss everything else, which is why a bug can live in this
 * path for as long as this one did while the suite stayed green.
 *
 * So the shape is chosen at random from a seed and every read is verified
 * against what the file is supposed to contain. Both the seed and the op
 * number are inputs and are printed on failure, so a failure replays exactly:
 *
 *     randwr --seed=NNN --ops=N --file=/mnt/self/r.bin
 *
 * Verification is only worth anything if the read cannot be answered out of
 * the writer's own page cache, so before a verified read the file is fsynced
 * and the cache is dropped. When --verify-file names a path on another mount,
 * the verified reads are taken from there instead: that is a different NFS
 * client, so its reads reach the server by construction.
 *
 * Sizes run from 265 bytes to 100000007 - deliberately not round numbers, and
 * including both sides of every power of two and every unit size this path
 * has had - and the data alternates between incompressible, all-zero and
 * repeated, because which of those a unit holds is what decides whether the
 * codec's frame is large or small.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint64_t rng_state;

static uint64_t rnd(void)
{
	uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return z ^ (z >> 31);
}

/*
 * Lengths worth trying. Everything here is one of: a power of two, one byte
 * either side of one, an encoded unit's size or either side of it, or a size
 * no boundary explains. 100000007 is the top of the range that was asked for.
 */
static const size_t edges[] = {
	265, 266, 511, 512, 513, 1000, 1023, 1024, 1025, 2047, 2048, 2049,
	4095, 4096, 4097, 5000, 8191, 8192, 8193, 16383, 16384, 16385,
	32767, 32768, 32769, 65535, 65536, 65537, 100000, 131071, 131072,
	131073, 200000, 262143, 262144, 262145, 500000, 1048575, 1048576,
	1048577, 2000000, 2097151, 2097152, 2097153, 4194304, 4194305,
	8388607, 8388608, 8388609, 16777215, 16777216, 16777217,
	33554432, 33554433, 67108864, 67108865, 100000007,
};

enum { DATA_RANDOM, DATA_ZERO, DATA_REPEAT };

static const char *data_name[] = { "random", "zero", "repeat" };

static size_t max_file = 160u << 20;
static unsigned char *model;
static unsigned char *buf;

static void die(const char *what)
{
	fprintf(stderr, "randwr: %s: %s\n", what, strerror(errno));
	exit(2);
}

static void fill(unsigned char *p, size_t len, int mode, uint64_t key)
{
	size_t i;

	switch (mode) {
	case DATA_ZERO:
		memset(p, 0, len);
		break;
	case DATA_REPEAT:
		for (i = 0; i < len; i++)
			p[i] = (unsigned char)("nfs"[i & 3] ^ (key & 0xff));
		break;
	default:
		for (i = 0; i < len; i++) {
			/* incompressible, and different for every offset */
			uint64_t z = (key + i) * 0x9E3779B97F4A7C15ull;
			z ^= z >> 29;
			p[i] = (unsigned char)(z >> 33);
		}
		break;
	}
}

/* pwrite/pread do not have to move everything at once, and a short one is
 * itself the bug this is looking for - so both are looped and both report. */
static void put(int fd, const void *p, size_t len, off_t off)
{
	size_t done = 0;

	while (done < len) {
		ssize_t n = pwrite(fd, (const char *)p + done, len - done,
				   off + done);
		if (n < 0)
			die("pwrite");
		if (n == 0) {
			fprintf(stderr,
				"randwr: FAIL short write at %llu: %zu of %zu\n",
				(unsigned long long)off + done, done, len);
			exit(1);
		}
		done += n;
	}
}

static void get(int fd, void *p, size_t len, off_t off, const char *what)
{
	size_t done = 0;

	while (done < len) {
		ssize_t n = pread(fd, (char *)p + done, len - done, off + done);
		if (n < 0)
			die("pread");
		if (n == 0) {
			fprintf(stderr,
				"randwr: FAIL short read (%s) at %llu: %zu of %zu\n",
				what, (unsigned long long)off + done, done, len);
			exit(1);
		}
		done += n;
	}
}

static size_t pick_len(void)
{
	size_t want;

	if (rnd() % 4) {
		want = edges[rnd() % (sizeof(edges) / sizeof(edges[0]))];
	} else {
		unsigned bits = 8 + (rnd() % 20);
		want = 1 + (size_t)(rnd() & ((1ull << bits) - 1));
	}
	if (want > max_file)
		want = max_file;
	if (want < 265)
		want = 265;
	return want;
}

/*
 * Half the offsets are flat random, which is already as far from a boundary as
 * a number can be. The rest are put on a boundary on purpose and then moved
 * off it by one of the small odd amounts this path has had to handle.
 */
static off_t pick_off(size_t len)
{
	uint64_t room = max_file - len;
	off_t off;

	if (rnd() % 2) {
		off = (off_t)(rnd() % (room + 1));
	} else {
		static const off_t nibble[] = { 0, 1, 265, 511, 512, 4095, 4096 };
		off = (off_t)((rnd() % (room / 4096 + 1)) * 4096);
		off += nibble[rnd() % (sizeof(nibble) / sizeof(nibble[0]))];
		if (off > (off_t)room)
			off = (off_t)room;
	}
	return off;
}

static uint64_t ops_done, bytes_written, hi_water, verifies, mismatch_op;

static void report(const char *what, off_t off, size_t at, unsigned char exp,
		   unsigned char got, uint64_t op)
{
	fprintf(stderr,
		"randwr: FAIL %s op=%llu busiest=%llu high_water=%llu "
		"off=%llu first_bad=%llu exp=%02x got=%02x\n",
		what, (unsigned long long)op, (unsigned long long)ops_done,
		(unsigned long long)hi_water, (unsigned long long)off,
		(unsigned long long)(off + at), exp, got);
	mismatch_op = op;
}

int main(int argc, char **argv)
{
	const char *path = NULL, *vpath = NULL;
	uint64_t seed = 1;
	unsigned long ops = 200;
	int fd, vfd;
	off_t size = 0;
	unsigned long i;

	for (i = 1; i < (unsigned long)argc; i++) {
		if (!strncmp(argv[i], "--seed=", 7))
			seed = strtoull(argv[i] + 7, NULL, 0);
		else if (!strncmp(argv[i], "--ops=", 6))
			ops = strtoul(argv[i] + 6, NULL, 0);
		else if (!strncmp(argv[i], "--file=", 7))
			path = argv[i] + 7;
		else if (!strncmp(argv[i], "--verify-file=", 14))
			vpath = argv[i] + 14;
		else if (!strncmp(argv[i], "--max-size=", 11))
			max_file = strtoull(argv[i] + 11, NULL, 0);
		else {
			fprintf(stderr, "randwr: unknown argument %s\n", argv[i]);
			return 2;
		}
	}
	if (!path) {
		fprintf(stderr, "randwr: --file=PATH is required\n");
		return 2;
	}

	rng_state = seed;

	/*
	 * Piped output is block-buffered by default, which puts the stderr
	 * failure line ahead of the progress lines it belongs after - and the
	 * harness reading the tail then keeps the wrong end of it. A tester
	 * whose failure output is lost at the moment it matters is no tester.
	 */
	setvbuf(stdout, NULL, _IOLBF, 0);

	model = malloc(max_file);
	buf = malloc(max_file);
	if (!model || !buf)
		die("malloc");
	memset(model, 0, max_file);

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		die(path);
	vfd = vpath ? open(vpath, O_RDONLY) : fd;
	if (vfd < 0)
		die(vpath);

	printf("randwr: seed=%llu ops=%lu max_size=%zu file=%s verify=%s\n",
	       (unsigned long long)seed, ops, max_file, path, vpath ?: path);

	for (i = 1; i <= ops; i++) {
		unsigned r = rnd() % 100;
		ops_done = i;

		if (r < 70) {
			size_t len = pick_len();
			off_t off = pick_off(len);
			int mode = (int)(rnd() % 3);

			fill(buf, len, mode, (uint64_t)off ^ seed);
			put(fd, buf, len, off);
			memcpy(model + off, buf, len);
			if ((size_t)off + len > (size_t)size)
				size = off + len;
			if ((size_t)size > hi_water)
				hi_water = size;
			bytes_written += len;
			printf("randwr: %llu write off=%llu len=%zu %s\n",
			       (unsigned long long)i, (unsigned long long)off,
			       len, data_name[mode]);
			if (rnd() % 8 == 0 && fsync(fd) < 0)
				die("fsync");
			continue;
		}

		if (r < 95) {
			/* a verified read: a range, or everything there is */
			size_t len;
			off_t off;
			size_t at;

			if (rnd() % 4 == 0) {
				off = 0;
				len = size;
			} else {
				len = pick_len();
				if ((size_t)len > (size_t)size || size == 0)
					len = size;
				off = size ? (off_t)(rnd() % (size - len + 1)) : 0;
			}
			if (!len)
				continue;

			/* the read has to come from the filesystem */
			if (fsync(fd) < 0)
				die("fsync");
			/*
			 * Reopened so the size and the data are the far side's
			 * current view: an fd held from before the first write
			 * has the size the file had then, which is zero.
			 */
			if (vpath) {
				close(vfd);
				vfd = open(vpath, O_RDONLY);
				if (vfd < 0)
					die(vpath);
			}
			if (posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED) < 0)
				die("fadvise");
			if (vfd != fd &&
			    posix_fadvise(vfd, 0, 0, POSIX_FADV_DONTNEED) < 0)
				die("fadvise");

			get(vfd, buf, len, off, "verify");
			verifies++;
			for (at = 0; at < len; at++) {
				if (buf[at] != model[off + at]) {
					report("verify", off, at, model[off + at],
					       buf[at], i);
					fprintf(stderr,
						"randwr: replay: --seed=%llu --ops=%lu\n",
						(unsigned long long)seed, i);
					return 1;
				}
			}
			printf("randwr: %llu verify off=%llu len=%zu ok\n",
			       (unsigned long long)i, (unsigned long long)off,
			       len);
			continue;
		}

		/* truncate, grow or shrink */
		{
			off_t want = (off_t)(rnd() % (max_file + 1));

			if (ftruncate(fd, want) < 0)
				die("ftruncate");
			/*
			 * A shrink discards for good, so the model has to
			 * forget those bytes rather than keep them: a later
			 * write, or a grow, leaves zeros there and a model
			 * still holding the old data would call that a
			 * failure. Zeroing is what "forget" means here.
			 */
			if (want > size)
				memset(model + size, 0, want - size);
			else if (want < size)
				memset(model + want, 0, size - want);
			size = want;
			printf("randwr: %llu truncate to %llu\n",
			       (unsigned long long)i, (unsigned long long)want);
		}
	}

	/* and once, everything, from the far side */
	if (size) {
		size_t at;

		if (fsync(fd) < 0)
			die("fsync");
		if (posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED) < 0)
			die("fadvise");
		get(vfd, buf, size, 0, "final");
		for (at = 0; at < (size_t)size; at++) {
			if (buf[at] != model[at]) {
				report("final", 0, at, model[at], buf[at], ops_done);
				fprintf(stderr,
					"randwr: replay: --seed=%llu --ops=%lu\n",
					(unsigned long long)seed, ops);
				return 1;
			}
		}
	}

	printf("randwr: ok seed=%llu ops=%lu written=%llu size=%llu "
	       "high_water=%llu verified=%llu\n",
	       (unsigned long long)seed, ops,
	       (unsigned long long)bytes_written, (unsigned long long)size,
	       (unsigned long long)hi_water, (unsigned long long)verifies);
	return 0;
}
