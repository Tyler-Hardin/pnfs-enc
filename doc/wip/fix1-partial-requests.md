# Fix 1: stop declining partial requests (work in progress)

Saved as `fix1-pnfs-layout.patch` and `fix1-bcachefs-tools.patch`. It compiles
and the suite runs, but it **breaks the read path** (`twophase`: `not_encoded`
800->820, every read refused), so it is not landed. This records the design,
the flaw, and the piece that was missing.

## The problem it addresses

`bc_write_pagelist()` declines any request whose `count` is not a multiple of
`unit_align`:

```c
	if (... || hdr->args.offset % bl->unit_align ||
	    hdr->args.count % bl->unit_align ||
	    hdr->args.pgbase % bl->unit_align)
		return PNFS_NOT_ATTEMPTED;
```

A file's last request can never be aligned, so it always takes
`pnfs_write_through_mds()` - and `write_declined == write_declined_align`
shows that path carries every partial request, about 6.6 per 148KB file with
the application's write pattern. That is both the throughput leak and the
route by which the file's tail reaches the reader late.

## The design

An encoded extent is described in sectors: `crc.uncompressed_size` is a sector
count and `bch2_encoded_write_unit()` refuses a unit whose length is not block
aligned. So a request whose last byte is not on a block boundary cannot be
written as itself. It has to be written **padded up**, and then:

- the descriptor must carry the **exact** length as well, because
  `new_i_size` is set from the unit's length and taking the padded length
  leaves every such file longer than it was written;
- the padding must be **zeros**, not whatever the page held, because those
  bytes are real and reachable - extending the file later reads them back,
  and a reader past the old end is owed zeros.

So: `valid_len` in the descriptor, `round_up(count, unit_align)` as the unit
length, a zeroed scratch buffer as the codec's input, and the backend sets
the inode's size from `valid_len`.

## Why it broke the read path

Padding makes the *write* produce an encoded extent whose key covers the
**padded** range. A later write into that range then splits it - and a split
rounds to a **sector**, so the pieces' live ranges no longer line up with what
the frame holds. The read either refuses the unit or, worse, serves the
stale frame. That is the same live-range/stale-frame mismatch we already fixed
once, reintroduced from the write side.

## The missing piece

The key's length must come from `valid_len`, not from the padded unit length:

    crc.live_size        = round_up(valid_len, block) >> 9   /* the key */
    crc.uncompressed_size = unit_len >> 9                    /* the frame */

The frame is then longer than the key, with the padding beyond it - which is
exactly the shape the live-range description was built to handle: the reader
takes `unit_len = live_size` from the key, `plain_offset = 0`, and never sees
the padding. That is the fix; it was not written.

## Also carried in the patch

- `bc_copy_from_pages()`, the mirror of `bc_copy_to_pages()`.
- `valid_len` on the descriptor and the wire. `ENCODED_DS_DESC_WORDS` is
  derived from the struct, so `BC_DS_READ_HEAD_WORDS` follows it - which is
  why that derivation exists.
- The backend's `new_i_size` from `valid_len`, and a check that
  `valid_len <= unit_len`.
