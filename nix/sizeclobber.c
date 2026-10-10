// SPDX-License-Identifier: GPL-2.0
/*
 * sizeclobber - two deterministic regressions for the encoded-write data
 * path, each a single process and each reached without any race window to
 * miss.
 *
 * clobber: an encoded write's size update used to copy the backend's own
 * idea of the file's size (bi_size, as committed through the btree so far)
 * onto the VFS inode (ATTR_SIZE through bch2_inode_update_after_write()),
 * rather than only ever growing it. The VFS i_size legitimately runs ahead of
 * bi_size whenever there is dirty, not-yet-written-back data past what the
 * btree has committed - every ordinary buffered write does that, extending
 * i_size as soon as it copies into the page cache and leaving the btree to
 * catch up at writeback. So: settle a file at some size with an fsync, then
 * extend it further *without* syncing (the dirty tail), then force a second,
 * independent encoded write to an *earlier*, already-settled, unit-aligned
 * range in the same file - an ordinary overwrite - and close. If the size
 * update for that overwrite clobbers the VFS size back down near where the
 * file was settled, the dirty tail is now past i_size, and this filesystem's
 * writeback zeroes and silently drops anything past i_size on every single
 * writepage call (a folio straddling i_size may be mmapped) - so the file
 * comes back shorter than it was written, with no error anywhere.
 *
 * This needs no timing: the overwrite's close() happens strictly after the
 * unsynced append's write() returns, in one process, so if the clobber exists
 * at all this always reproduces it - it is not a race to catch, only a
 * sequence to perform.
 *
 *     sizeclobber clobber <path> <unit> <units> <tail>
 *
 *   <unit>   the size to settle each unit-aligned write at (use the
 *            filesystem's actual encoded_extent_max, or something that
 *            divides it, so the overwrite is a whole encoded unit and not a
 *            partial one the driver would decline).
 *   <units>  how many such units to settle before the unsynced append.
 *   <tail>   how many further bytes to append without syncing.
 *
 * padding: a sub-sector write needs its sector's other bytes filled from the
 * file's own page cache, because the frame a codec produces is block-sized
 * and the key is sector-granular - and that is only the file's data while the
 * page supplying it is uptodate. NFS does not read-modify-write a partial
 * page unless the file is open for reading too, so an O_WRONLY writer's
 * fresh folio (never read in) is left not uptodate outside the bytes it
 * itself wrote; reading "the rest of the sector" out of it is reading
 * whatever the page happened to hold, not the file's bytes.
 *
 * Reproduced without any race by never giving the writer a reason to have
 * the page cached and uptodate: open, write a sector-misaligned length,
 * close - an append, not an overwrite, so there is nothing of the file's own
 * for this process to have read first - then read the file back through a
 * second path (a second mount, so a second client's page cache) and check
 * that the bytes before the misaligned tail are exactly what was written and
 * not some other value.
 *
 *     sizeclobber padding <path> <len> [readpath]
 *
 *   <len>      total bytes to write, deliberately not a multiple of 512.
 *   [readpath] read the result back through this path instead of <path> -
 *              the same point closeopen.c's trailing argument makes: a
 *              reader on the same mount can be answered from the cache the
 *              write just filled, which hides a server-side bug completely.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

static ssize_t pread_all(int fd, char *buf, size_t size, off_t off)
{
	size_t got = 0;

	while (got < size) {
		ssize_t n = pread(fd, buf + got, size - got, off + got);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			break;
		got += n;
	}
	return got;
}

static int do_clobber(const char *path, size_t unit, unsigned long units,
		      size_t tail)
{
	size_t settled = unit * units;
	size_t total = settled + tail;
	char *wbuf;
	int fd, ret = 0;

	wbuf = malloc(total);
	if (!wbuf) {
		fprintf(stderr, "out of memory\n");
		return 2;
	}
	/* Two distinguishable fills: the settled body and the unsynced tail. */
	memset(wbuf, 'A', settled);
	memset(wbuf + settled, 'B', tail);

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open");
		return 2;
	}

	/* Settle the body: a plain write, synced, so bi_size and the VFS
	 * i_size agree and every unit in it is a real, committed encoded
	 * extent - the overwrite below needs a real extent to land on. */
	if (write_all(fd, wbuf, settled) < 0) {
		perror("write (settle)");
		return 2;
	}
	if (fsync(fd) < 0) {
		perror("fsync (settle)");
		return 2;
	}

	/* Extend past the settled size, without syncing: this is the dirty
	 * tail the clobber drops. An ordinary application's append looks
	 * exactly like this - write() does not imply fsync(). */
	if (write_all(fd, wbuf + settled, tail) < 0) {
		perror("write (append)");
		return 2;
	}

	/* The overwrite: the first unit, unchanged contents, same offset.
	 * Still a whole, aligned unit, so still eligible for the encoded
	 * write path - which is the only path with a size update to clobber
	 * anything with. Its close() below has to run the size update after
	 * the unsynced append's write() already executed, which is
	 * guaranteed by this being one process running one statement after
	 * the other - there is no race to lose here. */
	if (pwrite(fd, wbuf, unit, 0) != (ssize_t)unit) {
		perror("pwrite (overwrite)");
		return 2;
	}

	if (close(fd) < 0) {
		perror("close");
		return 2;
	}

	/* Read back through a fresh open, the same process's own closeopen.c
	 * point: this is close-to-open, not a read from a cache this process
	 * never dropped. */
	{
		struct stat st;
		char *rbuf = malloc(total);
		ssize_t n;
		int rfd;

		if (!rbuf) {
			fprintf(stderr, "out of memory\n");
			return 2;
		}
		rfd = open(path, O_RDONLY);
		if (rfd < 0) {
			perror("open (readback)");
			return 2;
		}
		if (fstat(rfd, &st) < 0) {
			perror("fstat (readback)");
			return 2;
		}
		n = pread_all(rfd, rbuf, total, 0);
		close(rfd);

		printf("settled=%zu tail=%zu total=%zu stat_size=%lld read=%zd\n",
		       settled, tail, total, (long long)st.st_size, n);

		if ((size_t)st.st_size < total) {
			printf("FAIL: size clobbered: stat says %lld, wrote %zu "
			       "(dirty tail lost by %zu bytes)\n",
			       (long long)st.st_size, total,
			       total - (size_t)st.st_size);
			ret = 1;
		} else if (n < (ssize_t)total) {
			printf("FAIL: short read: got %zd of %zu\n", n, total);
			ret = 1;
		} else if (memcmp(rbuf, wbuf, total)) {
			size_t i;

			for (i = 0; i < total; i++)
				if (rbuf[i] != wbuf[i]) {
					printf("FAIL: byte %zu: wrote 0x%02x, "
					       "read 0x%02x\n", i,
					       (unsigned char)wbuf[i],
					       (unsigned char)rbuf[i]);
					break;
				}
			ret = 1;
		} else {
			printf("OK\n");
		}
		free(rbuf);
	}

	return ret;
}

static int do_padding(const char *path, const char *rpath, size_t len)
{
	char *wbuf, *rbuf;
	int fd, ret = 0;
	struct stat st;
	ssize_t n;

	if (len % 512 == 0) {
		fprintf(stderr, "padding: <len> must not be a multiple of "
				"512 - that is exactly the alignment this is "
				"testing a violation of\n");
		return 2;
	}

	wbuf = malloc(len);
	rbuf = malloc(len);
	if (!wbuf || !rbuf) {
		fprintf(stderr, "out of memory\n");
		return 2;
	}
	memset(wbuf, 'A', len);

	/*
	 * O_WRONLY, and a fresh file: there is nothing cached, nothing this
	 * process could have read in, so the only way this write's unit gets
	 * its sector-tail bytes right is if the driver declined to pad them
	 * from an un-uptodate page at all.
	 */
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open");
		return 2;
	}
	if (write_all(fd, wbuf, len) < 0) {
		perror("write");
		return 2;
	}
	if (close(fd) < 0) {
		perror("close");
		return 2;
	}

	fd = open(rpath, O_RDONLY);
	if (fd < 0) {
		perror("open (readback)");
		return 2;
	}
	if (fstat(fd, &st) < 0) {
		perror("fstat (readback)");
		return 2;
	}
	n = pread_all(fd, rbuf, len, 0);
	close(fd);

	printf("len=%zu stat_size=%lld read=%zd\n", len, (long long)st.st_size, n);

	if ((size_t)st.st_size != len) {
		printf("FAIL: size wrong: stat says %lld, wrote %zu\n",
		       (long long)st.st_size, len);
		ret = 1;
	} else if (n != (ssize_t)len) {
		printf("FAIL: short read: got %zd of %zu\n", n, len);
		ret = 1;
	} else if (memcmp(rbuf, wbuf, len)) {
		size_t i;

		for (i = 0; i < len; i++)
			if (rbuf[i] != wbuf[i]) {
				printf("FAIL: byte %zu (sector byte %zu of "
				       "%zu): wrote 0x%02x, read 0x%02x\n",
				       i, i % 512, len % 512,
				       (unsigned char)wbuf[i],
				       (unsigned char)rbuf[i]);
				break;
			}
		ret = 1;
	} else {
		printf("OK\n");
	}

	free(wbuf);
	free(rbuf);
	return ret;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		goto usage;

	if (!strcmp(argv[1], "clobber")) {
		size_t unit;
		unsigned long units;
		size_t tail;

		if (argc != 6)
			goto usage;
		unit = strtoul(argv[3], NULL, 0);
		units = strtoul(argv[4], NULL, 0);
		tail = strtoul(argv[5], NULL, 0);
		if (!unit || !units || !tail) {
			fprintf(stderr, "clobber: unit, units and tail must "
					"be non-zero\n");
			return 2;
		}
		return do_clobber(argv[2], unit, units, tail);
	}

	if (!strcmp(argv[1], "padding")) {
		size_t len;

		if (argc < 4 || argc > 5)
			goto usage;
		len = strtoul(argv[3], NULL, 0);
		if (!len) {
			fprintf(stderr, "padding: len must be non-zero\n");
			return 2;
		}
		return do_padding(argv[2], argc == 5 ? argv[4] : argv[2], len);
	}

usage:
	fprintf(stderr,
		"usage: %s clobber <path> <unit> <units> <tail>\n"
		"       %s padding <path> <len> [readpath]\n",
		argv[0], argv[0]);
	return 2;
}
