# Development

Repository layout, the edit/boot loop, the test bed, and the environment facts
that bite.

## Where everything is

```
flake.nix                modules, packages, checks
nix/kernel.nix           the patched 6.18 kernel and dsprobe
nix/bcachefs-module.nix  the out-of-tree backend module
nix/modules/             server.nix, client.nix, backend.nix (the NixOS modules)
nix/checks/              the module compile checks (C-only and Rust)
nix/patches/             the generated patches this repository builds from
nix/tests/               the two NixOS suites, the emulation bed, the profiles
nix/tests/data/          the LFS benchmark corpus
dev/                     the edit/boot loop and the patch generators
linux/                   the kernel checkout, branch `pnfs` (own repo, ignored)
bcachefs-tools/          the backend checkout, branch `master` (own repo, ignored)
CHECKOUTS                the revisions the patches were generated against
```

`linux/` is 6.18.50 plus the encoded-extent series on branch `pnfs`;
`bcachefs-tools/` is upstream `v1.39.6` plus the backend series on `master`.

## The patch is generated, the commits are the work

The tests build a kernel from `nix/patches/pnfs-layout-6.18.patch`, not from
`linux/`, and the module from `nix/patches/bcachefs-tools.patch`, not from
`bcachefs-tools/`. Both patches are *generated*:

```
dev/mkpatch.sh          # linux/ -> nix/patches/pnfs-layout-6.18.patch
dev/mkpatch-tools.sh    # bcachefs-tools/ -> nix/patches/bcachefs-tools.patch
dev/mkpatch.sh --check  # exit 1 if the patch is out of date
```

`mkpatch.sh` is `git diff --no-abbrev baseline` over an explicit file list -
`--no-abbrev` so the patch bytes do not change as the repository grows, and the
file list because a new file has to be added there, which is the reminder that
the patch's coverage is a decision. `CHECKOUTS` records the child revisions a
commit's artifacts belong with; the pre-commit hook regenerates it.

A kernel edit that has not been through `mkpatch.sh` is invisible to the tests:
they would build the previous kernel and pass. `run-nixos-test.sh` warns when
`linux/` and the patch disagree.

## The edit/boot loop

```
dev/kloop.sh                                        # btrfs, the control
TEST=bcachefs.nix dev/kloop.sh                      # bcachefs
PROFILE=gce-network-storage TEST=bcachefs.nix dev/kloop.sh
```

`kloop.sh` builds `linux/arch/x86/boot/bzImage` with `make` - the objects stay
in the tree, so an edit costs one recompile and the link steps - and boots that
kernel in the test through QEMU's `NIXPKGS_QEMU_KERNEL_<node>` hook. First use
adopts the test kernel's `.config` (`kbuild.sh --test-config`), which is
required: the initrd and module tree are still nix's, so the release string,
module ABI and built-in/module split have to match.

It does not cover a kernel config change or code built as a module; `kloop.sh`
says so before every run and names the result `...-wip`. The patch-based run is
the gate.

`kbuild.sh` is the compile check on its own:

```
dev/kbuild.sh                          # one object (default: the data service)
dev/kbuild.sh fs/nfs/bcachefs_ds.o
dev/kbuild.sh --image                  # incremental bzImage for kloop
```

## The gate

```
dev/mkpatch.sh && dev/mkpatch-tools.sh
dev/run-nixos-test.sh                                   # btrfs, the control
TEST=bcachefs.nix dev/run-nixos-test.sh                 # bcachefs
nix build .#checks.x86_64-linux.emulation -L            # the emulated link/disk, no kernel build
nix build .#checks.x86_64-linux.bcachefs-module-c -L    # the module, C-only (fast)
PROFILE=gce-local-nvme TEST=bcachefs.nix dev/run-nixos-test.sh
```

`run-nixos-test.sh` builds a patched 6.18.50 kernel and runs a multi-node
`nixosTest` from `nix/tests/`. A nix derivation that has already been built is a
no-op, so `PNFS_RERUN=1` forces a rerun. `WIP_KERNEL=<bzImage>` boots a kernel
built by `kbuild.sh --image` instead of the nix one, for the edit/boot loop.

There is an opt-in compiler cache for the ~50,000-compile kernel build:

```
mkdir -m 777 /var/tmp/pnfs-ccache            # once; outside $HOME, writable by the build user
PNFS_CCACHE=/var/tmp/pnfs-ccache dev/run-nixos-test.sh
```

`dev/ccache.nix` has the caveats (nixpkgs' per-derivation `-frandom-seed` has to
be ignored, `__TIME__` has to be in ccache's sloppiness list, and the build user
cannot reach a mode-700 `$HOME`, which is why the cache lives in `/var/tmp`). It
removes the recompiles, not the per-module links, `modpost`, `depmod` or the
store copies.

## The test bed

A VDE switch on the host and a qcow2 file in the host's page cache measure a
machine that exists nowhere: no round trip, no link rate, no storage latency.
`nix/tests/emulation.nix` is how a test asks for the link and disk a deployment
actually has:

- the link is shaped inside the node with `tc`/`sch_netem` on the *inter-VM*
  interface only (`eth0` is the test driver's own channel and must be left
  alone), and its rate with a qdisc;
- storage latency is a device-mapper `delay` target in front of the virtio disk
  (QEMU can throttle bytes and IOPS but has no per-IO delay), so the I/O still
  happens on a real virtio device and only its completion time is emulated;
- both are applied at boot and re-appliable at run time with `emulation-link`
  and `emulation-disk-<name>`, so a profile can be swept inside one boot. The
  test formats the `dm-delay` device (`/dev/mapper/<name>`), never the virtio
  disk underneath.

The bed's own floor is about 2.9 Gbit/s on the link and 14 GB/s on the disk;
delay is accurate to a few percent, loss is noisy, and one thing at a time is
what the numbers are for. `nix build .#checks.x86_64-linux.emulation` checks the
machinery without building a kernel.

`nix/tests/profiles.nix` is the table of machines:

| profile | link | export disk | client |
|---|---|---|---|
| `lan` | none | qcow2, host page cache | kernel defaults |
| `gce-network-storage` | 0.5 ms rtt | 1 ms, 570 MB/s | 4 vCPU, 32 RPC slots, 64 MiB window |
| `gce-local-nvme` | 0.5 ms rtt | local, no cap | 4 vCPU, 32 RPC slots, 64 MiB window |
| `wan-network-storage` | 20 ms rtt, 200 Mbit/s | 1 ms, 570 MB/s | 4 vCPU, 32 RPC slots, 64 MiB window |

The client column matters as much as the link: the kernel's defaults are two
outstanding RPCs and 128 KB of readahead, and the deployment's client is worth
5-6x on buffered reads. A comparison that does not hold the client fixed is a
comparison of clients.

The benchmark corpus (`nix/tests/data`) is 7.3 GB of real data in the repository
through LFS, deliberately. A 256 KiB unit of it encodes to a median 8.5 KiB and
a mean 24 KiB - three orders of magnitude more payload than the synthetic
`'P'`-repeated files the suites used before. It is meant to cost the store one
copy: `auto-optimise-store` hardlinks every later flake-source copy to the same
inode, and the guests read the files as read-only raw disks rather than copies
of them. `/dev/disk/by-id/virtio-corpus-test1` is how a test reads one.

## Environment facts and traps

- `/dev/kvm` is not visible to your shell (the tool sandbox's `/dev` is
  minimal), but the tests are KVM-accelerated: this machine declares the `kvm`
  system feature and nix exposes `/dev/kvm` to the build. Do not mistake the
  per-iteration cost for emulation - it is the full patched-kernel rebuild nix
  does on a kernel-source change. Use `kbuild.sh` for the compile check and
  batch the test runs.
- `/tmp` does not persist between tool calls. Use `~/.cache` or the workspace.
- The host PATH is minimal (no `make`, `gcc`, `bindgen`); build through nix.
- A hard NFS mount retries forever: bound every mount with `timeout` and check
  the exit code, or a failure hangs the run.
- `rpcinfo` cannot probe the data service (deliberately not registered with
  rpcbind). Use `dsprobe`.
- The runner uses the *registry* nixpkgs (26.05, kernel 6.18.50), not the flake
  lock (26.11). 7.2.x nfsd needs `nfsdcld` in this environment or the first
  `EXCHANGE_ID` blocks forever; 6.18 does not, which is why the base is 6.18.
- The release string of a hand-built kernel has to equal the module tree's
  (`CONFIG_LOCALVERSION_AUTO` off, `LOCALVERSION=""`, plain `6.18.50`), and the
  Rust support needs `RUST_LIB_SRC` or `olddefconfig` quietly drops
  `CONFIG_RUST` and the bcachefs module fails to load. `kbuild.sh` sets both.
- Artifacts cannot live inside the checkouts: git refuses to add a file in
  another repository's worktree, `-f` included, which is why everything this
  repository owns is at the top level and `CHECKOUTS` is how the two revisions
  are pinned.
- A delegation is granted asynchronously: poll `/proc/fs/nfsd/clients/*/states`
  for the grant instead of reading it once after the open. Reading it once
  passes on an idle machine and fails on a loaded one.

## A reasonable first hour

1. Read [`design.md`](design.md), then [`security.md`](security.md).
2. `git -C linux log --oneline v6.18.50..pnfs` and read the series; it is the
   specification. Then `git -C bcachefs-tools log --oneline v1.39.6..master`.
3. Run one suite to confirm the environment: `dev/run-nixos-test.sh` (first
   build 6-10 minutes, then minutes).
4. For the data service, read `fs/nfsd/encoded_ds.c`'s `encoded_ds_authenticate`
   and `encoded_ds_open` next to `fs/nfsd/nfsfh.c`'s `__fh_verify` and
   `nfsd_acceptable`, and `net/sunrpc/svcauth.c`'s `svc_set_client`.
