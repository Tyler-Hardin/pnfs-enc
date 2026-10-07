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

## 1. A write pgio must account for every byte, or say why not

`bc_write_finish()` reports success with

```c
	hdr->res.count = hdr->args.count;
```

unconditionally. `args.count` is what the caller asked for; `res.count` is
what the client will believe was written. Nothing compares them against what
the driver actually handed to the service. `io->left` counts exactly that, and
is the natural check:

- `WARN_ON_ONCE(io->left)` in the success path — finishing with bytes unaccounted
  for is the dropped-pgio bug, and it should be loud the first time it happens
  rather than inferred twenty runs later from a short file.
- A counter, `ds_write_leftover`, so it is visible in debugfs on a box where a
  WARN in dmesg was missed.

This is the 1-in-40. The failure is a file truncated to the page boundary below
its last write — everything up to the final pgio persisted, the final pgio did
not, and `close()` reported nothing. `res.count` being assigned rather than
derived is why the client believed the write was complete.

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

## The one design change worth making

Of the three, the third generalises. `nfs_server_is_local()` is asked by
different layers at different times about the same I/O, and the answer decides
which verifier namespace, which commit path and which page cache applies. That
is a property of the *mount*, not of the call. It should be read once, stored
on the client's mount state with the write, and the commit should compare
against the copy the write recorded — which turns "these two layers disagree"
from a livelock into a warning.
