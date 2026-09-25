# Security shape

The data service is the part of this that can hand out data, so it is the part
to read before touching anything else.

## The model

Clients are trusted with the *data* - anyone who can reach the data service may
read and write whatever the export machinery resolves - but no bug and no
malicious client may corrupt the filesystem. NFS permissions, read-only exports
and snapshots are the answer to the access questions, exactly as they are for
NFS.

The service is a **trusted-LAN service**: its port has no transport security of
its own, so it belongs behind the same network boundary as nfsd. That is a
deployment property, not something the code enforces or checks.

## What the service enforces

The data service does not invent authorization; it uses nfsd's own.

- `encoded_ds_authenticate()` calls `svc_set_client()`, the helper lockd uses:
  it sets `rq_client` from the caller's credentials and denies a caller nfsd
  does not know. The NULL procedure is still allowed, so the service can be
  probed.
- Every file is resolved and opened by `encoded_ds_open()` through
  `nfsd_open()`, which runs `fh_verify()`: the export is found by fsid for
  *this* client (`rq_client`), the handle is checked to be inside the export
  (`nfsd_acceptable`), and root and all-squash are applied (`nfsd_setuser`).
  Mode bits and read-only exports are checked by `nfsd_permission()`.
- The open runs on the client's credentials, and the task's credentials are
  restored per request.
- `NFSD_MAY_NOT_BREAK_LEASE` is used, for the same reason nfsd's COMMIT uses it:
  the writer reaches the file through the MDS first, and that open is what
  breaks the delegation. It is not a coherence hole.
- A mount that is not AUTH_UNIX is offered no layout rather than a downgrade, so
  a `sec=krb5` export behaves as ordinary NFS. The data service's own RPC client
  is created with the mount's credentials.

## What the filesystem half guarantees

Every write goes through the backend's own allocation, checksum and validation;
a payload the backend will not describe is refused rather than stored; anything
not understood falls back to plain NFS; encryption is refused, not
reimplemented; no checksum code is duplicated.

## Tested refusals

The suites send forged and out-of-policy requests, with a positive control:

- a handle outside the export is refused with STALE (70);
- a request presenting another uid against a root-only inode is refused with
  EACCES;
- an AUTH_NULL request against a `sec=sys` export is refused with WRONGSEC
  (10016).

The control is the handle exactly as handed out, which is served.

Known gaps: adversarial export membership with two filesystems, a read-only
export on a second filesystem, and a positive GSS path.
