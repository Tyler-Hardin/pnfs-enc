# Review: what crosses the client/server boundary, and what checks it

Written after three bugs in this change set, two of them mine. They are not
three unrelated mistakes. Each one is a **value that crossed the boundary
carrying an assumption the other side did not share**, and in each case
nothing checked the assumption on arrival:

| bug | value | client assumed | server meant |
|---|---|---|---|
| same-host hang | write verifier | "the commit returns this" | local I/O answers commits with its own |
| zero tail | unit length | "this unit covers `unit_len` bytes" | the *frame* is that long; the *key* is shorter |
| dropped pgio (1/40) | ? | ? | ? |

The pattern is the point. A layout driver is a place where two independently
written halves agree by convention, and conventions need checking where they
meet. bcachefs is defensive in exactly this way: `BUG_ON` only where the
kernel is already broken, `WARN_ON` and a counter where a peer could be lying
or a race could have happened, and every one of them says in a sentence what
invariant was violated.

So the redesign this document argues for is not "add checks everywhere". It is:
**every value received from the other side is validated against the invariant
it is used for, at the point of use, and a violation is a WARN plus a counter,
never a silent substitution.** Three concrete places follow, in priority order.

## 1. A write pgio must account for every *extent*, not just every byte

**Corrected.** This section first claimed that

```c
	hdr->res.count = hdr->args.count;
```

was the bug - that assigning the count rather than deriving it let the client
believe an incomplete write was complete. That is wrong, and reading the code
properly (which adding the counter below is what prompted) shows why: `io->left`
is decremented per unit in `bc_write_done()` and is zero before the success path
is reachable, so the driver does account for every byte, and `res.count` there
hides nothing. The claim was written from the shape of the failure rather than
from the code, which is the mistake this document exists to argue against.

The real gap is narrower and was hiding behind the wrong one. `io->left`
reaching zero proves `args.count` was *consumed*. It does not prove it was
consumed as one run from `args.offset`: an offset that overshot, or stopped
short, leaves bytes the caller asked for unwritten, and the caller is told the
whole request succeeded either way. What went unchecked was the **extent**, not
the count.

That check is now in `bc_write_finish()`:

- `WARN_ON_ONCE(io->offset != hdr->args.offset + hdr->args.count)`.

Still worth having, but as a guard against the next tiling mistake rather than
as the explanation of this failure - it has not fired, and the remaining 1-in-40
is not this.

## 2. The unit the service returns must be checked against the request

`bc_read_done()` already validates that the returned unit contains the offset
being read (`io->offset < desc->unit_offset || io->offset >= unit_end` →
fallback). It does *not* check the part that broke: that the unit's **length**
is one the key can back. The backend now refuses a frame longer than its key,
but the client should not depend on the server having been fixed — a peer is
allowed to be wrong, and the client is where that has to be survivable:

- `WARN_ON_ONCE` when the returned `unit_len` is not block-aligned, or exceeds
  `unit_max`, or when `unit_offset + unit_len` runs past the inode's size by
  more than one block.
- A counter for each, so a server-side regression shows up as a number rather
  than as corrupt data in a file someone has to notice.

## 3. The verifier's provenance must be explicit, not inferred

The same-host hang was that `bc_write_finish()` took the verifier from the
service while the commit was answered by local I/O, which uses its own. The fix
asks `nfs_server_is_local()` at write time. That is right, but it is a *query
made twice* — once here, once by whichever layer answers the commit — and if
those two disagree, the write is re-dirtied forever with no diagnostic.

- Log once (ratelimited) when a commit's verifier does not match the one the
  write carried, in the client's commit path. That is the symptom of exactly
  this class, and today it is invisible: the pages are simply rewritten and the
  counters only look busy.
- Assert that a write and its commit agree on the verifier's *source*, not just
  its value: `nfs_server_is_local()` is cheap and the disagreement is the bug.

## Deliberately not proposed

- **No `BUG_ON`.** A peer that returns nonsense, or a race that only happens
  under load, must not take the box down; that is the user's explicit
  constraint and bcachefs' own rule. Every check above is a WARN plus a
  counter, and the fallback path stays the correct answer.
- **No new protocol fields yet.** Each of these three is checkable with what
  already crosses the wire. If `unit_len` and the decode length need to be
  told apart properly (they do, for the clip-and-continue version of the read
  fix), that is a protocol change and should be its own decision, not smuggled
  into a hardening pass.

## The one design change worth making: stop owning a read path

Everything above is a tripwire. This is the actual change, and it supersedes
the rest.

The encoded read picks its own device:

```c
	fs/encoded_extent.c:183   bch2_bkey_pick_read_device(c, k, NULL, &pick, -1, 0);
	                          if (!ret) return bch_err_throw(c, encoded_no_extent);
```

Mainline's read does the same call with the state that makes it correct:

```c
	fs/data/read.c:1591       bch2_bkey_pick_read_device(c, k, failed, &pick, dev, flags);
	                          if (unlikely(!ret)) return read_extent_hole(...);
```

Two things are missing as a result, and both are the sort that only show up on
a filesystem that is not healthy:

- **`failed` is NULL.** It is what lets a second attempt avoid the device that
  just failed; with NULL we re-pick the same device every time and cannot
  retry around a bad one, a stale one, or a cached copy that is not the
  authoritative one.
- **`flags` is 0, and a hole is a refusal rather than a hole.** `read_extent_hole`
  exists to zero-fill a hole or reservation with the right accounting; going to
  the MDS instead is safe but is a different behaviour from every other reader
  on the same file.

Neither is visible on a healthy single-device filesystem, which is why a bed
that has never been degraded, never had a promote cache and never lost a member
cannot reproduce any of it.

The narrow duplication is deliberate and should stay: the *bio* already goes
through mainline with `BCH_READ_encoded|BCH_READ_last_fragment`, because the
point of this path is to hand a peer the stored frame rather than decoded
plaintext. What must not be duplicated is the **lookup and its error
semantics**. The rule:

> Call the same helper the data path calls, with the same arguments it passes.
> Where a difference is genuinely required - here, not decoding - copy the
> mainline function and change the minimum, so the diff against upstream stays
> readable and a future fix upstream is one this code inherits rather than
> misses.

Concretely: drive the encoded read through `__bch2_read_extent()` with the
encoded flag and let it do the pick, the retry, the EC reconstruction and the
hole, rather than reaching into `bch2_bkey_pick_read_device()` directly. Every
one of the three bugs in this document is a divergence from the data path in
exactly this sense, and each was found the hard way rather than by diffing.
