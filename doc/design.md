# Design

What the feature is, the contracts on the wire and in the kernel, and the
decisions behind them. [`../README.md`](../README.md) is the overview;
[`security.md`](security.md) is the security model; [`gotchas.md`](gotchas.md)
is what running it taught.

## The goal

Let a client read and write a filesystem's **compressed extents** over NFS with
the codec work moved to the client: the server sends the encoded bytes as they
sit on disk - no decompression on a read, no re-compression on a write - and the
client decompresses into its page cache and compresses its writes.

It is done as a **pNFS layout type**, not a new filesystem or a FUSE daemon, and
that is the central decision. Page cache, readahead, writeback, mmap, locking,
recovery, attribute and dcache coherence, the RPC transport, and the server's
export machinery are all stock NFS; the new code is only the data path plus one
RPC program for the encoded payloads. Every inability to serve a range degrades
to ordinary NFS, which is always correct.

The plumbing is filesystem-agnostic: each filesystem supplies one
`encoded_extent_ops` vtable and its codecs. bcachefs is the intended filesystem
and works; btrfs was the control and works too.

## The data path

### The wire

The data service is an RPC program of its own, `ENCODED_DS_PROGRAM`
(`0x2000BC01`), version 2, with the procedures NULL / PROBE / READ / WRITE. It
listens on TCP port 2050 (`nfsd.encoded_ds_port`, `vs_hidden`, not registered
with rpcbind) and uses AUTH_UNIX.

A separate program rather than new NFS operations, because the payload is one
whole encoded extent plus a small descriptor rather than an NFS-shaped
page-sized READ, and because riding on sunrpc gets transport, request slots,
reconnects, timeouts and several requests in flight for free.

Files are named the way NFS names them - export path plus file handle, resolved
with `exportfs` and nfsd's own open - so the service needs no
filesystem-specific identity on the wire.

### The layout

Layout type `LAYOUT_BCACHEFS_ENCODED` (6, experimental). The layout body
(version 4) carries the service address and port, the file handle and its
length, the per-inode encoded-extent ceiling and alignment, and **the names of
the codecs the export may use**. A descriptor then names a codec by *position in
that list*. The body carries no export path and no `fh_type`: the service
resolves the file by fsid through `fh_verify()`.

### The kernel side

`->read_pagelist` / `->write_pagelist` do the work. Reads fetch whole encoded
units, decode them, and copy the intersection into the request's pages; writes
compress whole units client-side and store them. Both are asynchronous: a
request covering several units chains them, each completion issuing the next,
because a synchronous call inside `read_pagelist` serialises every unit behind a
round trip. One unit is in flight per request; the pgio carries several
requests.

The request size is `bc_pg_bsize()`:

    min(max(unit_max * pg_units, rsize|wsize), BC_PG_BSIZE_MAX)   /* 8 MiB */

`pg_units` (debugfs, default 1, max 16) exists because the right value depends
on the stored unit size and the reader's shape, and a knob costs less than a
guess. An oversized request is safe: `nfs_pageio_reset_read_mds()` /
`write_mds()` reset `mirror->pg_bsize` to rsize/wsize, so a fallback
re-coalesces at the MDS's own transfer size, and the pgio's page array is sized
per request from `pg_count`.

### The codec boundary

The exporting filesystem owns the naming; the peer owns the implementation.
`struct encoded_extent_codec` is `{owner, compression, name, decode, encode}`.

A filesystem publishes the codecs it stores extents with on its
`encoded_extent_ops` table, and every *server-side* resolution - the names a
layout offers, the position-to-numbering translation in the data service, the
numbering-to-position one on the way back - reads that table. The registry in
`fs/encoded_extent.c` is only what the *peer* needs: names registered per layout
type, resolved to implementations, with a module reference.

btrfs registers `zstd` (128 KiB units); bcachefs registers `bcachefs-zstd`
(256 KiB default `encoded_extent_max`; its framing has the exact compressed
length in a little-endian u32 in front of the frame, and a name must be unique
within a layout type). An extent whose number has no registered codec - btrfs's
zlib and lzo, bcachefs's lz4 and gzip - is refused and falls back.

A name the client cannot resolve is asked for as a module by alias
(`encoded-extent-codec-<name>`), validated and rate limited because the name
came from a peer.

### Falling back

- Before the request is attempted: return `PNFS_NOT_ATTEMPTED`, and NFS sends it
  through the MDS.
- After the driver has taken the request: set `hdr->pnfs_error` and call
  `pnfs_ld_read_done()` / `pnfs_ld_write_done()`.
- `-ENODATA` from the service means "not served encoded": a hole, an inline,
  nocow or encrypted extent, an unregistered codec, a payload the backend
  refuses. The client treats it as a fallback and counts it; any other status
  also falls back through the MDS, counted as an error.

### Limits

- A unit is read with one bio, so the largest unit the read path can serve is
  `BIO_MAX_VECS * PAGE_SIZE` (1 MiB). A filesystem configured above that reports
  a `unit_max` of zero, which means "cannot be served"; the server then refuses
  the layout with `NFS4ERR_LAYOUTTRYLATER` instead of handing out one that every
  range would be refused on.
- The wire payload is `ENCODED_DS_MAX_PAYLOAD` (2 MiB), and the write path can
  store that; the read path cannot unless the unit ceiling allows it. A unit
  that does not fit is refused by the service, not truncated.

## Durability

The write path carries NFS's stability levels on the wire
(`enum encoded_extent_stable`: `UNSTABLE` / `DATA_SYNC` / `FILE_SYNC`). A backend
may always do more than it was asked, and must never claim more than it has
done: a level below a data sync needs no work and is reported as what it is, and
a durable request syncs the unit's own plaintext range - the data alone for a
data sync, the data and the metadata for a file sync - because a request may
start inside a unit and syncing past its end would make the call responsible for
data it did not write.

The reply carries what was actually reached plus the serving netns's own write
verifier (`nfsd_copy_write_verifier()`), so a COMMIT compares against the value
the MDS would hand out. DATA_SYNC is never produced by the client; a file-level
commit of unstable data-service writes routes through the MDS (which is the same
filesystem here).

## Coherence

The MDS *is* the data service, so the layout's per-inode limits cannot go stale,
the server-side inode is shared, and writes are coherent without a real
`LAYOUTCOMMIT` (`proc_layoutcommit` just returns `nfs_ok`). Splitting MDS and DS
later turns those two shortcuts into work: the limits become a call to the data
service, and layout commit becomes real.

Three things make the two-client case work anyway:

- every write has to open the file on the MDS first, and that open breaks a
  delegation, so `NFSD_MAY_NOT_BREAK_LEASE` in the data service's open is not a
  coherence hole (the writer's own RPC gets JUKEBOX and retries after the
  recall);
- `nfsd4_insert_layout()` recalls another client's layout for the same file;
- a bcachefs encoded write updates the btree inode, the in-memory inode's size
  and times, and the VFS inode's `i_blocks`, and invalidates the page cache, so
  nfsd's change attribute (which is the VFS ctime here) moves and the server does
  not serve stale contents after a write that bypassed the cache.

Per-unit latest-write-wins is the same semantics the MDS path gives.

## Authorization

Every file is resolved and opened with the presenting client's credentials
through nfsd's own `fh_verify()`/`nfsd_open()`, so export membership, subtree
containment, permissions, root and all-squash, and read-only exports are
enforced exactly as the MDS enforces them. See [`security.md`](security.md).

## Performance

The benchmark is the same file down both paths - an NFSv3 mount of the same
export is the MDS control - cold client caches, direct and buffered, best of
three, with the service's RPC count and the time it spends in the backend
(`read_ns`/`write_ns`) alongside. The shape that matters:

- The request must cover whole units, or the next request re-fetches what the
  previous one pulled; `ds_read_wasted` is the counter, and the request size is
  the fix (the two-deep walk was cut because it helped only
  one-request-at-a-time direct I/O).
- The cost is server-side and per unit: bcachefs's btree transaction, checksum
  and copies are the largest single number in the runs.
- The kernel's NFS client defaults are a ceiling - `sunrpc.tcp_slot_table_entries`
  is 2 and readahead is 128 KB - and neither alone does anything. The test
  profiles carry the deployment's client (32 slots, a 64 MiB window), which is
  worth 5-6x on buffered reads.
- The data service saturates at its thread count; writes to one shared file are
  the hot point. `pg_units` above about 4 loses on the beds measured, so its
  default stays 1.

What is left: the write window (the encode of unit N+1 waits for the reply to
unit N), the per-unit backend cost, and the codec workspace each unit allocates
on both sides.

## Decisions already made - don't relitigate without new information

- pNFS layout type rather than a new filesystem or FUSE. Fallback is free and
  always correct, and the "hardening for free" argument is weaker than it first
  looks: nfsd's state machinery adds its own failure modes.
- MDS == DS for now.
- `-ENODATA` means "not served encoded" at every layer; the fallback is the MDS.
  A refusal is never an error the user sees.
- The backend owns checksums; encryption is refused, not implemented. A peer
  never supplies a checksum or a key.
- The codec is *named* on the wire; the server's table belongs to the
  filesystem, the peer's to the layout type.
- 6.18 LTS as the base (7.2.x had an nfsdcld-related mount hang in this
  environment; never claimed to be a mainline bug, does not reproduce on 6.18).
- Locking is refused; multi-client is latest-write-wins; performance first.
- The data service is a separate sunrpc program, not new NFS operations.
