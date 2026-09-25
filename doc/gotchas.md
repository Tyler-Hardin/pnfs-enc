# Things that only showed up by running

Every entry here cost time to find and is cheap to avoid. Most are properties
of the kernel interfaces this rides on, not of this code. The numbers are the
position in this list, and `nix/tests/` refers to them by number.

1. The layout body needs its *own* opaque length prefix, or the client reads the
   first four body bytes as the length and the feature never works at all.

2. `pnfs_curr_ld->sync` is called with no NULL check from `nfs_wb_all()`, so a
   driver without `.sync` jumps to address zero on the first write.

3. Kernel buffers need `iov_iter_kvec()`, not `iov_iter_init()`; the latter
   builds a *user* iovec iterator and the copy faults with `-EFAULT`.

4. `rpc_version.counts` and `rpc_program.stats` are incremented unguarded by
   `call_start()`: both must exist or the client oopses writing to address 4.

5. The data service must bind IPv4 *and* IPv6, and must not start before
   `inet6_init()` - hence lazy start on the first LAYOUTGET.

6. `probe` must refuse an uncompressed extent exactly as `read` does.

7. A completed encoded write must set `hdr->verf.committed`, or NFS walks a pnfs
   commit path the driver does not have - and answering `NFS_FILE_SYNC` without
   syncing anything hides a lost acknowledged write instead. The honest answer
   is reachable now: `pnfs_mark_request_commit()` dereferences a NULL `cinfo->ds`
   for a driver with no commit hooks, which is why asserting `FILE_SYNC` used to
   be load-bearing rather than lazy.

8. A hardcoded codec check *looks* like it works; only the codec-table A/B shows
   whether the lookup is real. Keep that test.

9. The data path has to be asynchronous, with per-call contexts freed in
   `rpc_release`.

10. bcachefs's `compression` option is not accepted at mount time in this
    version ("set via sysfs opts dir") - set it at format time, or every extent
    is uncompressed and every encoded read is refused.

11. bcachefs stores a compressed payload block-padded, with the exact length
    inside the codec's framing; a peer's frame must be padded to `block_size`
    (and the checksum covers the padded unit) or the write is refused.

12. A client and server that disagree on the RPC authentication flavor is
    invisible until the *server* checks it. The data service's RPC client was
    created with `RPC_AUTH_NULL`, which no one could notice while the service did
    no authorization; the moment `fh_verify`/`check_security_flavor` ran, the
    export's `sec=sys` refused every read and write with `NFS4ERR_WRONGSEC`
    (10016). The service logging the raw status is what made it a five-minute
    diagnosis.

13. Opening a file on the server can break the *client's own* delegation. The
    layout holder holds a delegation on the file it is writing through the data
    service, so `nfsd_open`'s lease break recalls it from the very client blocked
    in writeback and fails with `nfserr_jukebox` (10008) - the first writes
    succeed, then every one after the delegation is granted fails. nfsd's
    `NFSD_MAY_NOT_BREAK_LEASE` is the answer (`COMMIT` uses it for the same
    reason).

14. `sync(2)` is not a durability barrier for NFS. There is no `->sync_fs`, and
    `ksys_sync()` wakes the async flusher first, which writes the pages out
    *unstably* (`WB_SYNC_NONE` clears the stable level) before the sync
    writeback reaches them - so the "write back stably" pass finds nothing to do.
    `fdatasync(2)` on the file is the barrier: it writes back and then COMMITs. A
    durability test has to use it, or `sync -d FILE`.

15. The client only asks for a stable *write* in narrow shapes, and the tests
    need all of them: the mount must be `write=lazy` (with the default `eager`,
    `nfs_writepages()` never computes a stable level for a plain fsync), and the
    range must fit in one pgio - a writeback that spans more than one sets
    `pg_moreio`, and `nfs_generic_pgio()` drops `FLUSH_COND_STABLE` for it. The
    common writeback shape is unstable and durable only after the COMMIT.

16. A commit checks the server's write verifier against the one the write
    carried, and rewrites the data if they differ. The data service therefore has
    to hand out *nfsd's own* verifier (`nfsd_copy_write_verifier()`) - the same
    value the MDS's own WRITE/COMMIT replies carry - not a value of its own, and
    not nothing: zeros mean the compare never matches and every page is
    rewritten forever.

17. bcachefs's encoded write updated the btree inode's size but not the
    in-memory VFS inode's, so a file it extended read as empty: to a GETATTR, to
    a read, and to the NFS client, whose own size was then clobbered back to zero
    on the next revalidation. `i_size_write()` under `i_lock` is what the
    buffered path does. The test that caught it compares the size on both sides,
    because two empty files hash the same - a digest-only check passes vacuously.

18. A backend may refuse a perfectly well-formed unit: bcachefs pads the payload
    to the block size and refuses it when the padding is not *smaller* than the
    unit, so a one-block encoded unit can never be served. Tests that want a
    stable write need a unit of a few blocks (64 KiB does for both backends), and
    a small write falls back to the MDS exactly as intended.

19. "The backend updated the inode" is three separate things on bcachefs: the
    btree key, the in-memory `bch_inode_info`, and the VFS inode. The encoded
    write updated the first only, which cost two separate bugs - the VFS `i_size`
    (a file that read as empty) and then the VFS mtime/ctime (a second client
    serving a stale copy, because nfsd's change attribute for this filesystem
    *is* the VFS ctime - it publishes no change cookie). One mechanism covers all
    of it: `bch2_inode_update_after_write()` with the attribute mask, which is
    what every other bcachefs inode update does after its commit.

20. A write that bypasses the page cache has to invalidate it, or the *server*
    serves the old contents: the MDS reads through the same page cache, so an
    NFSv3 client (or any fallback read) asks nfsd, nfsd asks the cache, and gets
    data the btree no longer has. bcachefs's own O_DIRECT path is the model
    (`bch2_pagecache_block_get` + `bch2_write_invalidate_inode_pages_range`);
    btrfs's encoded write already did it. A two-client test only sees this
    because one of the two readers must go through the MDS - give the second
    client an NFSv3 mount and it falls out immediately.

21. A delegation does *not* need breaking by the data service, because every
    write has to open the file on the MDS first, and *that* open breaks it (the
    writer's own RPC gets JUKEBOX and retries after the recall). The
    `NFSD_MAY_NOT_BREAK_LEASE` in the data service's open is therefore not a
    coherence hole. Layouts are recalled separately and already:
    `nfsd4_insert_layout()` recalls another client's layout for the same file,
    which `disable_recalls = true` does *not* disable - it only skips the layout
    lease.

22. A codec name arrives from a peer and ends up in a `request_module()` call,
    so it is a name handed to modprobe by a remote decision: character-validate
    it first (it has to be able to be part of a module alias) and rate limit
    repeats, or a layout naming a hundred codecs becomes a hundred modprobes.
    Making it observable was the other half - a counter of asks is what lets a
    test distinguish "loaded on demand" from "was already there".

23. The two halves of "which codec?" are asked by different sides and want
    different scopes. The server asks what *this filesystem* stores, so its
    answer must come from the filesystem (`encoded_extent_ops->codecs`) - a
    registry keyed by layout type cannot answer it, because two filesystems under
    one layout type have different numbering. The peer asks who implements a
    *name*, which is inherently per layout type. Conflating the two is what made
    "two backends at once" look like a registry-keying problem.

24. An RPC reply buffer is sized by the *procedure table*, not by the request.
    `p_replen` becomes `rq_rcvsize` in `call_allocate()`, `xprt_sock` receives
    into exactly that much (`xs_read_xdr_buf()` returns `-EMSGSIZE` past it), and
    a request that asks for more than the table reserved gets a truncated reply
    that no decoder can tell from a transport failure. The client asked for a
    whole unit's payload while the table still reserved 128 KiB, so every
    bcachefs extent compressing by less than 2:1 was served, truncated and
    quietly re-read through the MDS - with no wrong bytes, no error and no
    counter to say so. The fix makes the request and the reservation one number,
    and then removes the reservation's role entirely: `rpc_prepare_reply_pages()`
    receives the payload into the caller's pages (what an NFS READ reply does
    with the pages it is reading into), so `p_replen` is the head alone and the
    bound is the wire's 2 MiB. The header size there is in XDR *words*, not
    bytes - passing bytes puts the payload 120 bytes into the wrong place,
    silently, which is a mistake worth having made once.

25. "The backend updated the inode" has a *fourth* face on bcachefs (item 19
    named the other three): `bi_sectors` in the btree, `ei_inode` in the
    in-memory inode, and the VFS inode's `i_blocks` are all separate, and only
    `bch2_i_sectors_acct()` moves the last one - which every other write path
    calls in its completion and the encoded path, having no completion of its
    own, did not. The file was right; `stat` reported zero blocks, quota saw
    nothing, and the next truncate underflowed the count and was counted as an
    fsck error. Assert the *number*, not just the data: `stat -c %b` against the
    size is two lines and would have caught it the first time.

26. A unit is read with **one bio**, and the bio layer's vector pool stops at
    `BIO_MAX_VECS` = 256 pages, i.e. 1 MiB: asking for more `BUG()`s inside
    `bvec_alloc()`, in a request path, and takes the serving thread with it. The
    client reads that as a timeout, backs off for `BC_DS_DOWN_SECS`, retries and
    dies again, so one oversized unit turns into a wedged service and an
    87-second read - with every *other* read silently falling back to the MDS.
    The wire can carry 2 MiB (`ENCODED_DS_MAX_PAYLOAD`) and the *write* path can
    store 2 MiB units (a bio with a caller-supplied vector table), but the read
    path cannot read one, so a filesystem formatted at 2 MiB can hold units the
    data service can never serve. bcachefs's own compression path clamps to
    `BIO_MAX_VECS * PAGE_SIZE` for the same reason; the encoded read path did
    not, and now does. Above the ceiling it reports a `unit_max` of 0, which
    means *this filesystem cannot be served at all*: the server offers no layout
    (`NFS4ERR_LAYOUTTRYLATER`), the client reads through the MDS from the start
    instead of paying a refused call per read, and the backend logs once with the
    option, the value and the fix. A unit size is a format-time option, so
    getting this wrong costs a reformat.

27. The kernel's NFS client defaults are the ceiling, and neither is obvious:

    - `sunrpc.tcp_slot_table_entries` is **2**: at most two outstanding RPCs per
      transport, for the mount *and* for the data service's own RPC client, which
      is a transport of its own. Two units in flight is the throughput of two
      units in flight, whatever the link does.
    - `/sys/class/bdi/<nfs-bdi>/read_ahead_kb` is **128 KB**: a window that never
      has a second request ready to fill the slots the first change opens.

    Measured together on one cold 1.06 GiB file over Google Cloud network
    storage: an `md5sum` fell from 28 s to 3.3 s (2.0 s of that is md5sum's own
    hashing), a raw read from 28 s to 1.99 s (~570 MB/s single stream, 683 MB/s
    with eight readers). Neither setting alone does anything. And because the
    data service's requests are sized from `max(unit_max, rsize)` when
    `pg_units` is 1, the default readahead lands requests ~4x smaller than a unit
    and `ds_read_wasted` runs ~3.8x - which is what `ds_read_wasted` exists to
    show.

28. Requests and encoded units are different lengths, and the service charges
    per unit. A request that ends inside a unit makes the next request fetch that
    unit again: measured in production, with 1 MiB requests over ~944 KB units,
    **1.8 service calls per stored unit and `ds_read_wasted` 0.68** - about 45%
    of the service's work spent re-fetching what a neighbouring request had
    already pulled. The request size is the driver's `pg_bsize`, set by
    `bc_pg_bsize()` in units of the layout's `unit_max`; the old
    `max(unit_max, rsize)` degenerates to exactly one unit precisely when
    `unit_max == rsize`, which is one of the commonest configurations. Sweep
    `/sys/kernel/debug/pnfs_bcachefs/pg_units` (1 = one unit per request; 4-8
    amortises the straddle) and judge it by `ds_read_wasted` and the service call
    count, not by throughput alone.

    Measured on the deployment-shaped bed: it is not free. A request cannot be
    bigger than the read that asked for it, so a reader with rsize-sized I/Os
    sees no effect from 1 to 16 at all; and where it does take effect, above 4 it
    *loses* - 865 to 490 MB/s direct, 871 to 450 buffered - because the walk is
    one unit deep, so units in flight = requests in flight, and a bigger request
    is fewer requests. The straddle this entry is about is worth amortising only
    where `ds_read_wasted` is actually moved by it; the default is 1.

29. **A soft RPC timeout does not reconnect, so a data-service client that loses
    its connection is never rebuilt on its own.** The service's calls are all
    soft (`rpc_call_async(..., RPC_TASK_SOFT, ...)` with a 15 s `to_initval`),
    and `rpc_check_timeout()` (`net/sunrpc/clnt.c`) gives up on a soft task
    without forcing the transport down; only the *hard* path below it calls
    `rpc_force_rebind()`. If the connection has gone away without a reset being
    seen - a half-open TCP connection, a service restart, the server being
    unreachable for a while - sunrpc still believes it is connected, so every
    call after that pays the full timeout. The driver built one client per layout
    header and kept it for as long as the layout lived, so that was not one
    timeout: it was one *per unit*, and the mount's data path stayed dead while
    the service was healthy. Measured: a 737 MiB read that takes ~0.5 s warm paid
    113 timeouts in one pass and could not finish inside `timeout 60`; the
    service's own `read` counter never moved, because the requests never arrived,
    and `ss` showed the client's socket in `TIME-WAIT` with nothing established.
    Two things made it hard to see: `ds_down_skips` stayed 0 - the requests
    paying the timeout were already in flight and never consulted the window -
    and the *fallback worked*, so the file still read, just one 15 s timeout per
    request's worth of it. The driver now condemns the client on the timeout that
    sets the down window (`bc_ds_clnt_drop()`), and refuses to build one while
    that window is set (`bc_ds_clnt_get()`), so recovery is one connection per
    `BC_DS_DOWN_SECS` instead of none. Note the shape this is *not*: dropping
    packets (the suite's failure-mode test) gives a clean connect failure and
    sunrpc reconnects by itself; only a connection that looks established but is
    not needs the client thrown away.

30. **The encoded read path leaked its bounce pages, one unit per read, until the
    server ran out of memory.** `bch2_encoded_read_unit()` takes its pages with
    `bch2_bio_alloc_pages_pool()` and returned them with `bio_put()`, which does
    not return pool pages - they come from `c->bio_bounce_bufs` and have to go
    back through `bch2_bio_free_pages_pool()` (which is what the write path and
    the normal read path in `fs/data/read.c` do, before the put, because the free
    zeroes `bi_vcnt`). So every encoded unit read leaked `encoded_extent_max`:
    256 KiB by default, ~7.5 GiB over a suite run at ~30,000 units. The shape it
    presents as is worth recognising, because none of it looks like a leak: the
    server spends minutes in reclaim (nfsd stops answering, the service's threads
    sit in `kvzalloc` with its `read` counter stopped and `inflight` 0, so both
    paths look dead while the server's *own* read of the file is still fast), and
    then NixOS's `panic_on_oom` turns it into `Kernel panic - not syncing: Out of
    memory`. The OOM report is what identifies it: `Mem-Info` accounts for a few
    hundred MB out of 8 GiB, with ~7.7 GiB held by neither anon, file, slab nor
    shmem - that is `vmalloc`, and `/proc/vmallocinfo`'s caller histogram names
    the function. Fixed in `fs/encoded_extent.c`; the gated wedge arm is the
    regression case (its diagnostics print the histogram and the memory trend per
    read).
