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
| unit | `desc.unit_len` | the part of the file one encoded extent describes: a frame, its codec, and a key |
| frame | `crc.uncompressed_size` | the plaintext the codec produced, of which the key owns `crc.live_size` |

## The quantities

| quantity | unit | established by |
|---|---|---|
| `i_size`, `new_i_size` | bytes | VFS |
| `hdr->args.offset`, `.count`, `.pgbase` | bytes | NFS: offset is the first byte, pgbase its offset within `pages[0]` |
| `io->offset`, `io->unit`, `io->left` | bytes | the layout driver's own bookkeeping |
| `desc.unit_offset`, `.unit_len`, `.valid_len` | bytes | the client fills them; the backend shifts them by 9 and aligns them against `block_bytes` |
| `desc.plain_offset`, `.unencoded_offset` | bytes | the probe converts `crc.offset` to bytes before filling it |
| `desc.compression` | a `BCH_COMPRESSION_TYPE_*` | translated from the wire's codec position by `encoded_ds_translate_codec()` |
| `desc.encrypted` | bool | — |
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
| `ENCODED_DS_DESC_WORDS`, reply head words | XDR words (4 bytes) | anything counting them is counting 4-byte units |
| `data_len` in the inline-data decision | bytes | the smaller of the bio and the bytes left to `new_i_size`, which is what makes it the *valid* length and not the payload |

## Rules that follow

- Bytes at every interface; sectors only at the btree boundary, reached by
  `>> 9` and left by `<< 9`. Those shifts are the only correct crossings.
- `crc.live_size` is not a free variable. It *is* `k->size` on the way out of
  the btree, so what a reader can see is fixed by the key, and the frame's
  remaining plaintext beyond it is padding.
- The key therefore covers `crc.uncompressed_size`, and
  `bch2_write_prep_encoded_data()` requires `uncompressed_size == live_size`
  before it will store a payload as it stands. A payload that disagrees is not
  refused - it falls through and is recompressed as though it were plaintext,
  which stores the frame as the file's data.
- So whatever the key covers is the write's to describe, padding included.
  Padding that is not the file's own bytes is data loss, and padding past
  `i_size` is the only part a gap is owed zeros for.
- A unit is aligned to `block_bytes`, not to `unit_align` as such: the checks
  that matter compare against `block_bytes(c)`, which happens to equal the
  layout's `unit_align` on every filesystem tested, but is not the same claim.

## What the units caught

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
