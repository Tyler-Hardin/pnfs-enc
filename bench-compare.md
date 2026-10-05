# pNFS encoded extents - client scaling work, before/after

Command (both runs):
  PNFS_RERUN=1 PNFS_CCACHE=/var/tmp/pnfs-ccache \
    PROFILE=gce-network-storage TEST=bcachefs.nix dev/run-nixos-test.sh

64 MiB single stream, cold caches, 0.5 ms rtt / 1 ms storage / 570 MB/s,
4-vCPU client with 32 slot-table entries and a 64 MiB readahead window.

| what                | before        | after         |
|---------------------|---------------|---------------|
| read  DS direct     |  130 MB/s     |  130 MB/s     |
| read  DS buffered   |  1.3 GB/s     |  1.4 GB/s     |
| read  MDS direct    |  176 MB/s     |  165 MB/s     |
| read  MDS buffered  |  231 MB/s     |  208 MB/s     |
| write DS            |  1.0 GB/s     |  987 MB/s     |
| write MDS           |  210 MB/s     |  195 MB/s     |
| read  backend       | 1074/910 us/RPC | 1016/834 us/RPC |
| write backend       |  969 us/RPC   |  974 us/RPC   |

MDS rows are the fallback path and are noisy between runs (166-231 MB/s); they
are not a comparison. The data-service path is unchanged within noise.

Reading it honestly: this bed is server-bound - the backend is ~0.9-1.0 ms per
unit and that is the whole cost - so the client-side copies and the client-side
transport pool were not the bottleneck at 64 MiB single-stream. What changed is
architectural: the write path encodes straight out of the request's pages into
the buffer the transport sends, the read path decodes straight into the pages it
is filling, the first unit of a write is no longer encoded on the client's single
writeback worker, and the data-service client can hold several transports.

## What is in the change

1. Codec interface: `encode`/`decode` take `struct encoded_extent_pages` (page
   array + offset + length), with a page iterator; the zstd stream driving is
   shared in `fs/encoded_extent.c` and used by both backends.
2. Write path: no `plain`/`comp` bounce, no copy into RPC pages; the unit is
   encoded into a buffer whose pages `xdr_write_pages` sends, and
   `->write_pagelist` queues a work item rather than encoding inline.
3. Read path: a whole-unit request decodes straight into the destination pages.
4. Multi-transport: `bc_ds_connections` (module parameter on `nfs`) round-robins
   a file's units across that many rpc_clnts/connections. Default 1: the pool
   hangs off the layout header, which is per inode, so >1 is connections per
   file. Moving the pool to the mount is the follow-up.
5. DS write send: the per-unit page allocation + memcpy is gone.

## Verification

- `bcachefs.nix` passes (partial-unit write, corpus sha256, two-client
  coherence, crash durability, ENOSPC, btrfs cross-backend read and write).
- The `btrfs.nix` control passes.
- The first attempt failed the btrfs cross-backend read (`ds_read_ok` did not
  advance): the decode helper returned -E2BIG on a full destination, but a full
  destination is a normal stop and the caller checks the decoded length. Fixed
  and re-run; `ds_read_ok` is back to 6 -> 25 as in the baseline.

## Left

- The write window (unit N+1's encode waits for unit N's reply) - unchanged.
- The codec workspace is allocated per unit; a per-request stream context would
  allocate once per request.
- The write send buffer is one `alloc_pages_exact` per unit rather than a reused
  ring.
- Moving the transport pool from the inode to the mount.
