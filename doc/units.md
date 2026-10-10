# Units

Every quantity this path handles, what unit it is in, and where that is
established. Most of the bugs in this feature came from assuming a unit rather
than checking one, and the units are not uniform: two fields can be named alike
and differ, and one field can be bytes at run time and sectors on disk.

When touching this code, find the quantity below before reasoning about it.

## The units

| unit | size | used for |
|---|---|---|
| byte | 1 | every offset and length in the VFS and NFS interfaces, and in the data-service wire protocol |
| sector | 512 | every on-disk length: `bkey.size`, every `crc.*_size`, `bpos.offset`, `bio.bi_sector` |
| page | 4096 | page-cache and `args.pgbase` arithmetic |
| block | `block_bytes(c)` | the granularity a key is described in, a checksum covers, and data is read and written in |
| unit | the request range a write is for | the bytes of the file one key covers: `[req_offset & ~511, round_up(req_offset + req_len, 512))` |
| frame | `desc.unit_len` / `crc.uncompressed_size` | the plaintext the codec produced, of which the key owns `crc.live_size` |

## The quantities

| quantity | unit | established by |
|---|---|---|
| `i_size`, `new_i_size` | bytes | VFS |
| `hdr->args.offset`, `.count`, `.pgbase` | bytes | NFS: offset is the first byte, pgbase its offset within `pages[0]` |
| `io->offset`, `io->unit`, `io->left` | bytes | the layout driver's own bookkeeping |
| `req_offset`, `req_len` (write) | bytes | the client: the request range the frame is for. The backend derives the key from these together with the frame |
| write `desc.unit_offset`, `.unit_len` | bytes | the client: where the frame's plaintext begins and how long it is; the backend shifts them by 9 and aligns them against `block_bytes` |
| read `desc.unit_offset`, `.unit_len`, `.plain_offset` | bytes | the backend: the live range's start and length, and `crc.offset` converted to bytes |
| `desc.compression` | a `BCH_COMPRESSION_TYPE_*` | translated from the wire's codec position by `encoded_ds_translate_codec()`, on either side |
| read `desc.encrypted` | bool | the backend; a write has no such field, because a peer cannot ask for one |
| the dead run before the request's first sector, and the request's end within the frame | bytes | `encoded_extent_unit_geometry()`, from `req_offset`/`req_len` and the frame - never off the wire |
| offsets passed to the fops' `read`/`write` | bytes | `encoded_extent_ops` |
| `len`, `padded_len` in `bch2_encoded_write_unit()` | bytes | `len` is the codec's frame; `padded_len = round_up(len, block_bytes(c))` |
| `bio.bi_iter.bi_size` | bytes | `bio_sectors()` divides by 512 |
| `op->pos.offset` | **sectors** | a `bpos` |
| `op->new_i_size` | bytes | compared against `i_size` |
| `bio.bi_sector` | sectors | set as `offset >> 9` |
| `crc.compressed_size` | sectors | `_compressed_size + 1` |
| `crc.uncompressed_size` | sectors | `_uncompressed_size + 1` |
| `crc.offset` | sectors | where the live part starts within the frame's plaintext |
| `crc.live_size` | sectors | **`bch2_extent_crc_unpack()` sets it to `k->size`**; there is no such field on disk |
| `k.k->size`, `bkey_start_offset()` | sectors | — |
| `block_bytes(c)` | **bytes** | returns `c->opts.block_size` directly (`fs/bcachefs.h`) |
| `block_sectors(c)` | sectors | `block_size >> 9` |
| `bucket_bytes()` / `ca->mi.bucket_size` | bytes / **sectors** | `bucket_size << 9` |
| `c->opts.encoded_extent_max` | **bytes** at run time | `OPT_HUMAN_READABLE`; on disk it is `OPT_SB_FIELD_SECTORS|OPT_SB_FIELD_ILOG2`, i.e. ilog2 of a sector count |
| `bl->unit_max`, `bl->unit_align` | bytes | the layout the client was offered |
| `ENCODED_DS_MAX_PAYLOAD` | bytes | — |
| `ENCODED_DS_WRITE_DESC_WORDS`, `ENCODED_DS_READ_DESC_WORDS`, reply head words | XDR words (4 bytes) | anything counting them is counting 4-byte units; the two descriptors are different shapes |
| `data_len` in the inline-data decision | bytes | the smaller of the bio and the bytes left to `new_i_size`, which is what makes it the *valid* length and not the payload |

## Rules that follow

- Bytes at every interface; sectors only at the btree boundary, reached by
  `>> 9` and left by `<< 9`. Those shifts are the only correct crossings.
- `crc.live_size` is not a free variable. It *is* `k->size` on the way out of
  the btree, so what a reader can see is fixed by the key, and the frame's
  remaining plaintext beyond it is padding.
- The key does *not* cover `crc.uncompressed_size`. A frame is a whole number
  of blocks and so reaches past the request at either end, but the file owns
  only the request's sectors, so the key stops there and the rest of the frame
  is dead. `bch2_write_prep_encoded_data()` stores a payload as it stands when
  `crc.offset + crc.live_size <= crc.uncompressed_size`, which is why a frame
  longer than its key is the normal shape rather than a refusal.
- So the only bytes the key names that the request did not send are the two
  sub-sector runs at its ends. Those are the file's own bytes, read out of the
  request's pages - which is why a request whose pages are not the file's page
  cache is declined rather than padded - and everything else in the frame is
  dead and owed zeros past `i_size`.
- A unit is aligned to `block_bytes`, not to `unit_align` as such: the checks
  that matter compare against `block_bytes(c)`, which happens to equal the
  layout's `unit_align` on every filesystem tested, but is not the same claim.

## What the units caught

- The key was assumed to cover `crc.uncompressed_size`, which made the frame's
  length and the file's ownership of it one quantity. They are not: the
  request's sectors are what the file owns, and a write whose key ran to the
  frame's end claimed up to a whole block of bytes it was never sent. Every bug
  in filling that padding was a bug in bytes the file did not own.
- `crc.uncompressed_size` and `crc.live_size` were assumed independent. They
  are equal for every ordinary writer and `live_size` is really `k->size`, so a
  unit whose frame is longer than its key falls through the write-as-is gate
  and has its frame stored as plaintext.
- `data_len` in the inline path was assumed to be the payload. It is the
  smaller of the payload and the bytes remaining to `new_i_size`, so it decides
  on the *valid* length - which is why small tails went to inline storage.
- `block_bytes()` returns bytes while `bucket_size` in the line above it is
  sectors.
- `encoded_extent_max` is bytes at run time and ilog2-sectors on disk, so
  `c->opts.encoded_extent_max >> 9` in `bch2_write_prep_encoded_data()` is a
  bytes-to-sectors conversion and correct; the same expression applied to the
  *on-disk* field would not be.
