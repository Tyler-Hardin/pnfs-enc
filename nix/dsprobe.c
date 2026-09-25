/*
 * dsprobe: a userspace client for the encoded-extent data service.
 *
 * The in-kernel client data path is the real consumer, but it is also the
 * hardest thing to debug from a test; this makes the service's wire
 * independently testable. Today it makes the one call that needs no file handle
 * and no codec - RPC NULL - which is enough to prove the program is registered,
 * the listener answers, the authenticator accepts, a thread picks the request
 * up, and the reply is well formed XDR. PROBE/READ/WRITE need an nfsd file
 * handle, which only the MDS has, so those belong to the kernel client.
 *
 * Not a production tool: no retries, no IPv6, exits non-zero on any failure.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <rpc/rpc.h>

#define ENCODED_DS_PROGRAM	0x2000BC01u
#define ENCODED_DS_VERSION	2
#define ENCODED_DS_NULL		0

static void usage(void)
{
	fprintf(stderr, "usage: dsprobe <host> <port> null\n");
}

int main(int argc, char **argv)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
	struct addrinfo *res = NULL;
	struct sockaddr_in sin;
	struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
	enum clnt_stat status;
	CLIENT *clnt;
	char portstr[16];
	int fd = RPC_ANYSOCK;
	long port;
	int rc;

	if (argc != 4) {
		usage();
		return 2;
	}

	port = strtol(argv[2], NULL, 0);
	if (port <= 0 || port > 65535) {
		fprintf(stderr, "dsprobe: bad port %s\n", argv[2]);
		return 2;
	}

	if (strcmp(argv[3], "null") != 0) {
		usage();
		return 2;
	}

	snprintf(portstr, sizeof(portstr), "%ld", port);
	rc = getaddrinfo(argv[1], portstr, &hints, &res);
	if (rc != 0 || !res) {
		fprintf(stderr, "dsprobe: cannot resolve %s: %s\n", argv[1],
			gai_strerror(rc));
		return 2;
	}
	sin = *(struct sockaddr_in *)res->ai_addr;
	freeaddrinfo(res);

	clnt = clnttcp_create(&sin, ENCODED_DS_PROGRAM, ENCODED_DS_VERSION,
			      &fd, 0, 0);
	if (!clnt) {
		clnt_pcreateerror("dsprobe: clnttcp_create");
		return 1;
	}

	status = clnt_call(clnt, ENCODED_DS_NULL,
			   (xdrproc_t)xdr_void, NULL,
			   (xdrproc_t)xdr_void, NULL, tv);
	if (status != RPC_SUCCESS) {
		clnt_perror(clnt, "dsprobe: NULL");
		clnt_destroy(clnt);
		return 1;
	}

	clnt_destroy(clnt);
	printf("NULL ok\n");
	return 0;
}
