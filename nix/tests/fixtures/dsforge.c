/*
 * dsforge: send encoded-extent data-service requests from userspace, with a
 * file handle and credentials of our choosing.
 *
 * The in-kernel client is the real consumer and the two-node test exercises it
 * end to end. What it cannot exercise is the service's *refusals*: a stock NFS
 * mount never reaches the data service for anything the MDS would deny, so a
 * denial is only observable if something presents a request the MDS would not
 * have granted. This is that something. It is a test tool, not a client.
 *
 * A real nfsd file handle comes from the client's debugfs
 * (/sys/kernel/debug/pnfs_bcachefs/layout_fh) - the handle the MDS actually
 * handed out in a layout. From there this can:
 *
 *   - send it back unchanged: the positive control;
 *   - substitute another file's fid (name_to_handle_at) while keeping the
 *     export's fsid: a handle for a file outside the export, which fh_verify
 *     must refuse (nfsd_acceptable) exactly as the MDS would;
 *   - present a different AUTH_UNIX uid/gid, or AUTH_NULL, which is how the
 *     per-file permission and security-flavor checks are exercised.
 *
 * The nfsd handle is [version, auth_type, fsid_type, fileid_type] + fsid +
 * fsid; the fid is exactly what name_to_handle_at returns (plus its
 * handle_type), so the substitution only has to keep the fsid prefix.
 *
 * Not a production tool: no retries, IPv4 only. Exits 0 whenever the RPC itself
 * succeeded - the interesting result is the status inside the reply; exits 1 on
 * an RPC failure (an authentication denial arrives this way).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <rpc/rpc.h>
#include <rpc/auth_unix.h>

#define ENCODED_DS_PROGRAM	0x2000BC01u
#define ENCODED_DS_VERSION	2
#define ENCODED_DS_PROBE	1
#define ENCODED_DS_READ		2
#define ENCODED_DS_WRITE	3

#define MAX_FH			128
#define MAX_PAYLOAD		(2u << 20)

struct ds_addr {
	struct {
		u_int	len;
		char	*bytes;
	} fh;
};

struct ds_probe_args {
	struct ds_addr	addr;
	uint64_t	offset;
	uint64_t	len;
};

struct ds_reply {
	int32_t		status;
	uint64_t	unit_offset;
	uint64_t	unit_len;
	uint64_t	unencoded_offset;
	uint32_t	codec;
	uint32_t	encrypted;
};

struct ds_read_args {
	struct ds_addr	addr;
	uint64_t	offset;
	uint32_t	buf_size;
};

/* A write reply carries no descriptor: the caller knows which unit it sent. */
struct ds_write_reply {
	int32_t		status;
	uint32_t	committed;	/* what the service actually reached */
	char		verf[8];	/* the netns write verifier */
};

struct ds_read_reply {
	struct ds_reply	reply;
	uint32_t	payload_len;
	char		*payload;
};

/*
 * WRITE carries a descriptor and a payload. The service opens the file before
 * it looks at either, so a WRITE with any payload is enough to test whether the
 * open is allowed (a read-only export refuses there).
 */
struct ds_write_args {
	struct ds_addr	addr;
	uint64_t	offset;
	struct {
		uint64_t unit_offset;
		uint64_t unit_len;
		uint64_t unencoded_offset;
		uint32_t codec;
		uint32_t encrypted;
	} desc;
	uint32_t	stable;		/* NFS's write levels: 0 unstable, 2 file sync */
	uint32_t	payload_len;
	char		*payload;
};

/* XDR has no portable u64 here; two u32 words, big-endian, are the same thing. */
static bool_t xdr_u64(XDR *xdrs, uint64_t *p)
{
	uint32_t hi = (uint32_t)(*p >> 32);
	uint32_t lo = (uint32_t)*p;

	if (!xdr_u_int(xdrs, &hi) || !xdr_u_int(xdrs, &lo))
		return FALSE;
	*p = ((uint64_t)hi << 32) | lo;
	return TRUE;
}

static bool_t xdr_ds_addr(XDR *xdrs, struct ds_addr *a)
{
	return xdr_bytes(xdrs, &a->fh.bytes, &a->fh.len, MAX_FH);
}

static bool_t xdr_ds_probe_args(XDR *xdrs, struct ds_probe_args *a)
{
	return xdr_ds_addr(xdrs, &a->addr) &&
	       xdr_u64(xdrs, &a->offset) &&
	       xdr_u64(xdrs, &a->len);
}

static bool_t xdr_ds_reply(XDR *xdrs, struct ds_reply *r)
{
	return xdr_int(xdrs, &r->status) &&
	       xdr_u64(xdrs, &r->unit_offset) &&
	       xdr_u64(xdrs, &r->unit_len) &&
	       xdr_u64(xdrs, &r->unencoded_offset) &&
	       xdr_u_int(xdrs, &r->codec) &&
	       xdr_u_int(xdrs, &r->encrypted);
}

static bool_t xdr_ds_read_args(XDR *xdrs, struct ds_read_args *a)
{
	return xdr_ds_addr(xdrs, &a->addr) &&
	       xdr_u64(xdrs, &a->offset) &&
	       xdr_u_int(xdrs, &a->buf_size);
}

static bool_t xdr_ds_read_reply(XDR *xdrs, struct ds_read_reply *r)
{
	if (!xdr_ds_reply(xdrs, &r->reply))
		return FALSE;
	r->payload = NULL;
	r->payload_len = 0;
	/* An error reply is the status and the descriptor only. */
	if (r->reply.status)
		return TRUE;
	return xdr_bytes(xdrs, &r->payload, &r->payload_len, MAX_PAYLOAD);
}

static bool_t xdr_ds_write_reply(XDR *xdrs, struct ds_write_reply *r)
{
	return xdr_int(xdrs, &r->status) &&
	       xdr_u_int(xdrs, &r->committed) &&
	       xdr_opaque(xdrs, r->verf, sizeof(r->verf));
}

static bool_t xdr_ds_write_args(XDR *xdrs, struct ds_write_args *a)
{
	return xdr_ds_addr(xdrs, &a->addr) &&
	       xdr_u64(xdrs, &a->offset) &&
	       xdr_u64(xdrs, &a->desc.unit_offset) &&
	       xdr_u64(xdrs, &a->desc.unit_len) &&
	       xdr_u64(xdrs, &a->desc.unencoded_offset) &&
	       xdr_u_int(xdrs, &a->desc.codec) &&
	       xdr_u_int(xdrs, &a->desc.encrypted) &&
	       xdr_u_int(xdrs, &a->stable) &&
	       xdr_bytes(xdrs, &a->payload, &a->payload_len, MAX_PAYLOAD);
}

/* fs/nfsd/nfsfh.h's key_len(): the fsid's length in bytes, by fsid_type. */
static u_int key_len(u_int type)
{
	switch (type) {
	case 0:		return 8;	/* FSID_DEV */
	case 1:		return 4;	/* FSID_NUM */
	case 2:		return 12;	/* FSID_MAJOR_MINOR */
	case 3:		return 8;	/* FSID_ENCODE_DEV */
	case 4:		return 8;	/* FSID_UUID4_INUM */
	case 5:		return 8;	/* FSID_UUID8 */
	case 6:		return 16;	/* FSID_UUID16 */
	case 7:		return 24;	/* FSID_UUID16_INUM */
	default:	return 0;
	}
}

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int parse_hex(const char *s, unsigned char *out, u_int *out_len)
{
	u_int n = 0;

	while (*s && n < MAX_FH) {
		int hi, lo;

		if (*s == '.' || *s == ':') {	/* tolerate separators */
			s++;
			continue;
		}
		hi = hexval(*s++);
		lo = *s ? hexval(*s++) : -1;
		if (hi < 0 || lo < 0)
			return -1;
		out[n++] = (hi << 4) | lo;
	}
	*out_len = n;
	return n ? 0 : -1;
}

static void print_hex(const unsigned char *p, u_int n)
{
	u_int i;

	for (i = 0; i < n; i++)
		printf("%02x", p[i]);
	printf("\n");
}

static void usage(void)
{
	fprintf(stderr,
		"usage: dsforge [options] <host> <port> probe|read|write\n"
		"       dsforge fid <path>            print a file's fid + type\n"
		"  -f <hex>    real nfsd handle from the client's layout_fh debugfs\n"
		"  -t <path>   substitute this file's fid into the handle (local path),\n"
		"              keeping the export's fsid; default: use -f as-is\n"
		"  -F <hex> -y <type>  the same with a fid computed elsewhere - how a\n"
		"              client forges a handle for a server-side file\n"
		"  -u <uid> -g <gid>  AUTH_UNIX credentials (default 0:0)\n"
		"  -a unix|null       auth flavor (default unix)\n"
		"  -o <offset> -l <len>  request offset and length (default 0 / 1 MiB)\n"
		"  -s <stable>  how durable a WRITE must be: 0 unstable, 1 data, 2 file\n");
}

int main(int argc, char **argv)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
	struct addrinfo *res = NULL;
	struct sockaddr_in sin;
	struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
	struct ds_addr addr = {};
	const char *hex = NULL, *subst = NULL, *fid_hex = NULL;
	const char *host, *portstr, *op;
	unsigned char raw[MAX_FH], forged[4 + 24 + MAX_FH];
	u_int raw_len = 0, forged_len, prefix;
	int fid_type = -1;
	enum clnt_stat status;
	int uid = 0, gid = 0, null_auth = 0;
	uint64_t offset = 0, len = 1 << 20;
	uint32_t stable = 0;
	CLIENT *clnt;
	int fd = RPC_ANYSOCK, c, rc;

	while ((c = getopt(argc, argv, "f:t:F:y:u:g:a:o:l:s:")) != -1) {
		switch (c) {
		case 'f': hex = optarg; break;
		case 't': subst = optarg; break;
		case 'F': fid_hex = optarg; break;
		case 'y': fid_type = atoi(optarg); break;
		case 'u': uid = atoi(optarg); break;
		case 'g': gid = atoi(optarg); break;
		case 'a': null_auth = !strcmp(optarg, "null"); break;
		case 'o': offset = strtoull(optarg, NULL, 0); break;
		case 'l': len = strtoull(optarg, NULL, 0); break;
		case 's': stable = atoi(optarg); break;
		default: usage(); return 2;
		}
	}

	/*
	 * A file's fid, to be carried to where the real handle is: the handle
	 * lives on the client (it came in a layout), the file to forge for lives
	 * on the server.
	 */
	if (optind < argc && !strcmp(argv[optind], "fid")) {
		struct file_handle *fh = calloc(1, sizeof(*fh) + MAX_FH);
		int mount_id;

		if (argc - optind != 2 || !fh) {
			usage();
			return 2;
		}
		fh->handle_bytes = MAX_FH;
		if (name_to_handle_at(AT_FDCWD, argv[optind + 1], fh, &mount_id, 0) < 0) {
			fprintf(stderr, "dsforge: name_to_handle_at(%s): %s\n",
				argv[optind + 1], strerror(errno));
			free(fh);
			return 2;
		}
		printf("type %d\nfid ", fh->handle_type);
		print_hex((unsigned char *)fh->f_handle, fh->handle_bytes);
		free(fh);
		return 0;
	}

	if (argc - optind != 3 || !hex) {
		usage();
		return 2;
	}
	host = argv[optind];
	portstr = argv[optind + 1];
	op = argv[optind + 2];

	if (parse_hex(hex, raw, &raw_len) < 0 || raw_len < 4) {
		fprintf(stderr, "dsforge: bad handle hex\n");
		return 2;
	}

	prefix = 4 + key_len(raw[2]);
	if (!key_len(raw[2]) || prefix > raw_len) {
		fprintf(stderr, "dsforge: handle has an unknown fsid_type %u\n",
			raw[2]);
		return 2;
	}

	forged_len = raw_len;
	memcpy(forged, raw, raw_len);
	if (subst || fid_hex) {
		unsigned char fid[MAX_FH];
		u_int fid_len = 0;
		int type;

		if (subst) {
			struct file_handle *fh = calloc(1, sizeof(*fh) + MAX_FH);
			int mount_id;

			if (!fh)
				return 1;
			fh->handle_bytes = MAX_FH;
			if (name_to_handle_at(AT_FDCWD, subst, fh, &mount_id, 0) < 0) {
				fprintf(stderr, "dsforge: name_to_handle_at(%s): %s\n",
					subst, strerror(errno));
				free(fh);
				return 2;
			}
			memcpy(fid, fh->f_handle, fh->handle_bytes);
			fid_len = fh->handle_bytes;
			type = fh->handle_type;
			free(fh);
		} else {
			if (parse_hex(fid_hex, fid, &fid_len) < 0 || fid_type < 0) {
				fprintf(stderr, "dsforge: bad -F fid hex or -y type\n");
				return 2;
			}
			type = fid_type;
		}

		forged[3] = type;
		memcpy(forged + prefix, fid, fid_len);
		forged_len = prefix + fid_len;
	}

	addr.fh.len = forged_len;
	addr.fh.bytes = (char *)forged;

	rc = getaddrinfo(host, portstr, &hints, &res);
	if (rc != 0 || !res) {
		fprintf(stderr, "dsforge: cannot resolve %s: %s\n", host,
			gai_strerror(rc));
		return 2;
	}
	sin = *(struct sockaddr_in *)res->ai_addr;
	freeaddrinfo(res);

	clnt = clnttcp_create(&sin, ENCODED_DS_PROGRAM, ENCODED_DS_VERSION,
			      &fd, 0, 0);
	if (!clnt) {
		clnt_pcreateerror("dsforge: clnttcp_create");
		return 1;
	}
	clnt->cl_auth = null_auth ? authnone_create() :
				    authunix_create("dsforge", uid, gid, 0, NULL);

	if (!strcmp(op, "probe")) {
		struct ds_probe_args args = { .addr = addr, .offset = offset, .len = len };
		struct ds_reply reply = {};

		status = clnt_call(clnt, ENCODED_DS_PROBE,
				   (xdrproc_t)xdr_ds_probe_args, (char *)&args,
				   (xdrproc_t)xdr_ds_reply, (char *)&reply, tv);
		if (status != RPC_SUCCESS) {
			clnt_perror(clnt, "dsforge: PROBE");
			clnt_destroy(clnt);
			return 1;
		}
		printf("status=%d unit_offset=%llu unit_len=%llu unencoded_offset=%llu codec=%u encrypted=%u\n",
		       reply.status, (unsigned long long)reply.unit_offset,
		       (unsigned long long)reply.unit_len,
		       (unsigned long long)reply.unencoded_offset,
		       reply.codec, reply.encrypted);
	} else if (!strcmp(op, "read")) {
		struct ds_read_args args = { .addr = addr, .offset = offset,
					     .buf_size = (uint32_t)len };
		struct ds_read_reply reply = {};

		status = clnt_call(clnt, ENCODED_DS_READ,
				   (xdrproc_t)xdr_ds_read_args, (char *)&args,
				   (xdrproc_t)xdr_ds_read_reply, (char *)&reply, tv);
		if (status != RPC_SUCCESS) {
			clnt_perror(clnt, "dsforge: READ");
			clnt_destroy(clnt);
			return 1;
		}
		printf("status=%d unit_len=%llu payload_len=%u codec=%u\n",
		       reply.reply.status,
		       (unsigned long long)reply.reply.unit_len,
		       reply.payload_len, reply.reply.codec);
		free(reply.payload);
	} else if (!strcmp(op, "write")) {
		/*
		 * The open happens before the payload or the descriptor is looked
		 * at, so a small zero payload is enough to ask "may this client
		 * write this file?" - which is all the read-only-export test
		 * needs.
		 */
		struct ds_write_args args = {
			.addr = addr,
			.offset = offset,
			.desc = { .unit_offset = offset, .unit_len = len },
			.stable = stable,
			.payload_len = 512,
		};
		struct ds_write_reply reply = {};

		args.payload = calloc(1, args.payload_len);
		if (!args.payload) {
			clnt_destroy(clnt);
			return 1;
		}
		status = clnt_call(clnt, ENCODED_DS_WRITE,
				   (xdrproc_t)xdr_ds_write_args, (char *)&args,
				   (xdrproc_t)xdr_ds_write_reply, (char *)&reply, tv);
		free(args.payload);
		if (status != RPC_SUCCESS) {
			clnt_perror(clnt, "dsforge: WRITE");
			clnt_destroy(clnt);
			return 1;
		}
		printf("status=%d asked=%u committed=%u verf=%02x%02x%02x%02x%02x%02x%02x%02x\n",
		       reply.status, stable, reply.committed,
		       (unsigned char)reply.verf[0], (unsigned char)reply.verf[1],
		       (unsigned char)reply.verf[2], (unsigned char)reply.verf[3],
		       (unsigned char)reply.verf[4], (unsigned char)reply.verf[5],
		       (unsigned char)reply.verf[6], (unsigned char)reply.verf[7]);
	} else {
		usage();
		clnt_destroy(clnt);
		return 2;
	}

	clnt_destroy(clnt);
	return 0;
}
