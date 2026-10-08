# Review: local I/O in the kernel side of the layout driver

The encoded layout was written before local I/O was understood, and the
verifier livelock was found the hard way rather than by review. This is that
review done deliberately: which parts of the kernel side have to know that a
client can be mounted on its own server, and what each one's answer is.

The count is the finding. `fs/nfs/bcachefs_layout.c`, `fs/nfs/bcachefs_ds.c`,
`fs/nfsd/bcachefs_layout.c` and `fs/nfsd/encoded_ds.c` between them mention
local I/O exactly once - in the fix below. Everything else was written
assuming a server somewhere else, which for a same-host deployment is not
wrong so much as unexamined. So the review is the enumeration: for each place
where "the server is local" changes the answer, does this code give the right
one?

## 1. The write verifier - was hand-rolled, now reuses local I/O

**Was:** `bc_write_set_verf()` decided whether the write's verifier should be
the service's hashed one or the client's record of the server's boot, and in
the second case built it by hand:

```c
	u32 *v = (u32 *)hdr->verf.verifier.data;
	do {
		seq = read_seqbegin(&clp->cl_boot_lock);
		v[0] = (u32)clp->cl_nfssvc_boot.tv_sec;
		v[1] = (u32)clp->cl_nfssvc_boot.tv_nsec;
	} while (read_seqretry(&clp->cl_boot_lock, seq));
```

That is the body of `nfs_copy_boot_verifier()`, reached through
`nfs_set_local_verifier()`, which is what local I/O already calls for its own
writes (`fs/nfs/localio.c:931`) and commits (`:1034`). Two copies of a thing
with one owner is what put the read reply's payload eight bytes out; the same
shape here would mean a peer whose verifier quietly stops matching.

**Now:** the driver asks local I/O for the writeverf.
`nfs_set_local_verifier()` is exported and declared the way
`nfs_server_is_local()` already is, and the layout driver needs the symbol
because `nfsv4-$(CONFIG_PNFS_BCACHEFS_LAYOUT)` is a different object group
from `nfs-$(CONFIG_NFS_LOCALIO)`. The committed level is decided by the caller
and passed through unchanged, so the downgrade policy in `bc_write_finish()`
still holds.

## 2. The predicate - correct, and for a subtle reason

`bc_write_set_verf()` keys on `nfs_server_is_local(clp)`, and that had to be
checked rather than assumed, because the obvious wrong choice is "is the
server on this host":

```c
static inline bool nfs_client_is_local(const struct nfs_client *clp)
{
	return !!rcu_access_pointer(clp->cl_uuid.net);
}

bool nfs_server_is_local(const struct nfs_client *clp)
{
	return nfs_client_is_local(clp) && localio_enabled;
}
```

Both halves matter. `nfs_local_probe()` requires `localio_enabled` *and*
`AUTH_SYS` to mark a client local at all, so a same-host mount with local I/O
off - or over krb5 - has `nfs_server_is_local()` false and must be given the
service's hashed verifier, with the commit going over the wire. A predicate
that only asked "same host" would hand those mounts the boot verifier and
livelock them.

It is also the right question, not just a correct one: the pgio and commit
paths decide with a `struct nfsd_file *localio` handle, and that handle comes
from `nfs_local_open_fh()`, which begins

```c
	if (!nfs_server_is_local(clp))
		return NULL;
```

So the predicate the driver uses is the one that produced the handle the
commit will be answered through. The verifier and the commit cannot disagree
about whether the commit is local.

## 3. The commit's verifier - confirmed to come from there

`nfs_local_commit_done()` fills `data->res.verf` through
`nfs_set_local_verifier()`, so the value a commit is checked against really is
the client's boot record, and the fix in 1 is the matching source.

## 4. Build plumbing - two files the patch never carried

`dev/mkpatch.sh` carries an explicit file list, and `fs/nfs/internal.h` and
`fs/nfs/localio.c` were not in it. A change to either therefore never reached
the build. This is the most dangerous finding of the review, because the
failure is invisible: the first version of the reuse above failed to compile
with an *implicit declaration* of a function declared in a header the source
does include, which reads as a mistake in the caller. It is not a mistake it
is possible to see from the source tree alone.

Both files now differ from pristine only by this change (7 and 14 lines), and
both are in the list. Anything else that has to touch the local I/O
integration will need them there too.

## 5. What remains assuming a remote server, and why that is all right

- **The service is reached over the network even when the server is local.**
  Deliberate - the deployment spreads compression across per-file threads by
  putting the client and server on one host, and the comment in
  `bc_write_set_verf()` says so - but it does mean local I/O still pays a
  loopback RPC per unit. A cost, not a bug.
- **Credentials.** `bc_ds_read_async()`/`bc_ds_write_async()` authenticate as
  the caller rather than the mount; under local I/O the service runs the
  same nfsd access checks, so a mount credential would be root-squashed.
  Addressed separately.
- **The durability chain.** The service reports what it reached;
  `bc_write_finish()` passes FILE_SYNC through and downgrades DATA_SYNC to
  UNSTABLE so the client commits through the MDS, which on a local mount is
  answered locally. The server-side encoded write does not set
  `op->devs_need_flush`, and the only consumer of that field is the nocow
  path (`fs/data/write.c:1550`, inside `if (wbio->nocow)`), which this driver
  refuses - so it is inert here rather than fine.
- **`localio_enabled` is writable at runtime but sampled at mount time.**
  `nfs_local_probe()` reads it when the client is set up, while
  `nfs_server_is_local()` reads it live. Flipping the module parameter on a
  live mount would leave the *live* predicate false while the *cached* handle
  still routes commits locally - and the driver, which asks the live one,
  would then hand over the wrong verifier. This is local I/O's own fragility
  rather than something introduced here, but the driver now depends on the
  same predicate and inherits it. Treat the parameter as boot-only, or have it
  walk the clients.

## 6. Test coverage, and its limit

Every same-host arm runs with local I/O on, so the reuse above is exercised on
the branch it was written for. The other branch is exercised by the
remote-client arms, which reach it through `nfs_client_is_local()` being false
rather than `localio_enabled` - the same code path from a different input, so
"same host with local I/O off" is covered by construction rather than by a
dedicated arm. It would need one to be covered directly: `NFS_FS` is built in
(`lib.kernel.module` is not set for it), so there is no runtime toggle, and a
same-host mount with `nfs.localio_enabled=0` on the kernel command line means
another machine in the test.
