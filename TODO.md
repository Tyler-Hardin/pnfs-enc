# TODO

What is left, and how ready this actually is. The design is in
[`doc/design.md`](doc/design.md).

## Working, and tested

The data path both ways on btrfs and bcachefs, with a fallback at every layer;
authorization through nfsd's own `fh_verify`/`nfsd_open`, with the refusals
tested on the wire; NFS's stability levels and the serving write verifier on the
wire, with commits through the MDS; codec providers findable by module alias and
rate limited; the codec table owned by the filesystem rather than by the layout
type; durability across a server crash; two clients staying coherent; and the
backend's two promote paths - a read filling the cache, and `promote_on_write`
filling it from the write.

## Fixed: the truncated/partial-write reports

The actual cause of the truncation reports that motivated the last several
rounds of descriptor/live-range work was not in any of that work. Two
independent bugs, both now fixed (see `doc/gotchas.md` 32-38 for the full
account):

- **The size clobber (gotcha 32).** An encoded write's completion copied the
  btree's `bi_size` onto the VFS inode unconditionally
  (`bch2_inode_update_after_write(..., ATTR_SIZE|...)`), rather than only
  ever growing it. The VFS `i_size` legitimately runs ahead of the btree
  whenever there is dirty, unsynced data, so a data-service write
  completing after an MDS write to a later range pulled the file's visible
  size back down - and this filesystem's writeback silently drops
  whatever is past `i_size` on every call. This is almost certainly the
  dominant cause of "file came back truncated to a page/unit boundary,
  with no error reported anywhere."
- **The padding-from-a-not-uptodate-page hazard (gotcha 33).** A sub-sector
  write pads its unit from the request's own cached pages, on the
  assumption that those pages hold the file's bytes. They do, in general,
  only while the folio is uptodate - which an `O_WRONLY` writer's fresh
  page is not, unless something read it in first. This is a corruption
  bug (wrong bytes at the edges of a sub-sector write), not strictly a
  truncation, but it is reachable by the same append/overwrite shapes and
  worth ruling out or in separately.

Also fixed along the way, lower severity: a response descriptor built from
the wrong one of two `bch2_bkey_pick_read_device()` picks on a multi-replica
extent (gotcha 35); a read reporting manufactured zeros as a confident,
complete success when its walk stopped at a possibly-stale cached `i_size`
rather than a real EOF, instead of an honest short read NFS already knows how
to retry correctly (gotcha 34); the move path (rebalance/copygc) losing its
ability to reclaim a trimmed encoded extent's dead space, because a gate
meant only for the data-service write path was loosened for every encoded
writer (gotcha 38); a leaked `struct file` on every successful data-service
PROBE (gotcha 36); and the data service resolving its own address in the
wrong network namespace (gotcha 37).

**What this does not mean**: these fixes are reviewed against the code paths
they touch, and `nix/sizeclobber.c`'s two modes are deterministic,
race-free reproductions of 32 and 33 added to `nix/tests/bcachefs.nix` - but
the full NixOS VM suite has not been re-run end to end since. Before trusting
this on anything that matters, run it (`dev/run-nixos-test.sh` /
`nix flake check`) and confirm `sizeclobber clobber`/`sizeclobber padding`
pass and the existing suite still does too.

## Fixed: most of the read-side waste for a sequential reader

See `doc/gotchas.md` 39 for the full account. `bc_readahead_expand()` and
`bc_expand_read_folio()` widen a readahead window or a single-folio read to
an actual unit boundary (not just a unit-sized count, which `pg_units`
already gave it) - which is what a sequential reader's `ds_read_wasted`
figure (#27/#28, ~68% on the deployment-shaped bed) mostly turns out to be:
every unit re-fetched once by the request that straddled it and once more
by the neighbour that finished the job, for bytes the application reads
exactly once either way.

Measured on `nix/seqread.c`'s two arms (a small-file loop and one large
mmap'd file, both read sequentially through a second mount): waste fell to
under 4% (mmap) and under 0.02% (small files), full suite green on both the
`lan` and `gce-network-storage` profiles (`bcachefs`, `bcachefs-gce-network-storage`,
`btrfs`, `btrfs-gce-network-storage`, `promote`, `promote-on-write`, both
module checks, `emulation` - `bcachefs-kmsan` not run). Unlike the previous
entry, this one *was* taken all the way through the full suite before being
called done - see gotcha #40 for why that discipline mattered more than
usual this time.

**What is not covered**: this is the read side only; the same count-vs-offset
cut exists in the write path's `pg_test` too (still `pnfs_generic_pg_test`,
unmodified) and was deliberately left alone to keep the read measurement
uncontaminated - see the commit. `MADV_SEQUENTIAL` on the mmap side is not
required for correctness (`bc_expand_read_folio()` covers the un-hinted
case) but is still the cheaper, more predictable path where the application
can use it. And `pnfs_waste.sh` against a real workload, not `seqread.c`
against a synthetic one, is still the way to know what a given deployment
actually gets.

## What is next

### More tests

Still not covered: reconnect and retry mid-request (the failure-mode test drops
the port, which reconnects by itself; the transport-rebuild regression is a
gated arm), memory pressure, architectures other than x86_64, and a same-file
read A/B. Longer term these belong in a tracked home (ktest/xfstests) rather
than a NixOS test.

Two concurrent writers to one file are deliberately not tested: per-unit
latest-write-wins is what the MDS path gives too, and "one of these contents,
per unit" is not a useful assertion.

### A separate data-service node

The data service's COMMIT procedure and its commit hooks are what makes it a
*separate* node rather than the MDS. Today MDS == DS, so `proc_layoutcommit` is
a no-op and the per-inode limits cannot go stale; splitting them turns both of
those shortcuts into work.

### Upstreaming

The kernel series is the form to send. Two pieces are contentious: the new
`fs/encoded_extent.c` core file and its registry (decide where it really
belongs), and the durability wire change, which changes the data service
protocol version and adds a stability contract the core vtable carries. The RPC
program number needs an IANA assignment or a vendor range, and the layout type
number is experimental.

## Readiness, honestly

It is a working, well-tested **prototype, not production-ready**, for either
backend.

| | btrfs | bcachefs |
|---|---|---|
| works end to end | yes | yes |
| test depth | reads, writes, fallback, codec A/B, durability, crash, coherence (two clients), failure modes (unreachable service, ENOSPC, the payload ceiling), throughput, concurrency | the same, plus the backend promote checks (read-time, and write-time with `promote_on_write`) |
| coherence | two clients, incl. a held delegation and an NFSv3 reader | same |
| durability | stable/unstable both ways; commits through the MDS and the backend's own fsync | same |
| authorization | nfsd's own `fh_verify`/`nfsd_open` per request; refusals tested | same |
| code location | kernel tree patch | kernel patch **+ out-of-tree module** |

What production would require, in order: a decision on the trust/deployment
model (it is a trusted-LAN service: the data service port has no transport
security of its own and belongs behind the nfsd network boundary, and the GSS
path refuses rather than downgrading); the data service's COMMIT procedure and
commit hooks; the failure modes above; a perf pass on both backends; and an
upstream-or-vendor-patchset decision.
