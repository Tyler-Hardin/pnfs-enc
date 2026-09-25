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
