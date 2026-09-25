# pNFS encoded extents

A pNFS layout type that hands an NFS client a filesystem's **stored compressed
extents** and lets the client do the codec work.

Normally an NFS server decompresses a read and re-compresses a write. Here the
server serves the compressed, checksummed blob exactly as it sits on disk, and
the client decodes it - so the CPU cost of compression moves to the machine that
has spare CPU, and the bytes on the wire are the smaller ones. Writes go the
other way: the client compresses, the server stores the result through the
filesystem's own write path, checksums and all.

Nothing else about the mount changes. Namespace, attributes, coherence, locking,
recovery and the fallback path are stock NFS; the layout driver owns only the
data path, and any range it cannot serve - a hole, an uncompressed or encrypted
extent, a codec the client does not have, a service that is not answering - goes
back to the MDS, which is always correct.

It is a fork, not an upstream submission. The layout type number and the data
service's RPC program number are unregistered and experimental.

## Backends

| backend | encoded extents come from | state |
|---|---|---|
| **bcachefs** | the module in `bcachefs-tools`, built from the patches in `nix/patches/` | the target, tested end to end |
| **btrfs** | the encoded read/write ioctls, factored into a backend in the kernel patch | the control, same suites |

## Status

Verified by two NixOS VM suites that run a server, a client and a second client,
and check the data path in both directions, the failure modes, durability across
a server crash and coherence between two clients, plus a backend promote check,
the emulation check and a C-only/Rust module build:

- **24 concurrent streams**, 16 MiB each: reads **2.3-2.7 GB/s** and writes
  **1.6-1.7 GB/s** through the data service, against **0.27-0.31 GB/s** for the
  same files through the MDS. Single-stream buffered reads run about 2.5x the
  MDS.
- The data service **saturates at its thread count** - it is the resource under a
  wide load, which is what `services.pnfsServer.threads` is for.
- Failure modes are exercised, not asserted: an unreachable service (a read
  still returns the right bytes, and the client stops paying a timeout per
  request), a full filesystem, and a unit whose encoded form is most of a
  megabyte.

Not verified, and worth knowing before trusting it: real hardware (all numbers
are KVM guests with virtio disks), memory pressure, architectures other than
x86_64, kerberos mounts, and the data service's own COMMIT procedure.
[`TODO.md`](TODO.md) is the honest list.

## Using it

Requires NixOS. The flake provides two modules and the packages.

Server - one that already mounts a bcachefs filesystem at `/srv/export`:

```nix
{
  inputs.pnfs-encoded-extent.url = "github:you/pnfs-encoded-extent";

  imports = [ inputs.pnfs-encoded-extent.nixosModules.server ];
  services.pnfsServer = {
    enable = true;
    export = "/srv/export";
    clients = [ "10.0.0.0/24" ];
    threads = 32;
  };
}
```

The module enables nfsd, adds the export with the flags the layout needs, opens
the data service's port (which is *not* nfsd's port, and which nothing else
opens), sets the service's thread count and port as kernel parameters, and loads
the bcachefs module. It does not mount the filesystem; that is yours.

Client:

```nix
{
  imports = [ inputs.pnfs-encoded-extent.nixosModules.client ];
  services.pnfsClient = {
    enable = true;
    mounts."/mnt/data" = { server = "fileserver"; };
  };
}
```

The client module carries the patched kernel and the codec provider - available
but not loaded, because the client loads it on demand when a layout names its
codec - and generates the mount with the options the layout needs (`vers=4.1`,
`write=lazy`).

Every consumer builds a kernel from source: the layout driver is in `fs/nfs`, so
the patch has to be applied, and no binary cache has that. Expect a 20-40 minute
build the first time, plus the bcachefs module.

Packages: `kernel`, `bcachefs-module`, `bcachefs-tools-src`, and `dsprobe` - an
ops tool that asks the data service whether it is answering, which `rpcinfo`
cannot do because the service is deliberately not registered with rpcbind.

## Expectations before you deploy

- **The data service must be the node holding the filesystem.** It resolves
  files by fsid through nfsd's own verification, and bcachefs is not a
  distributed filesystem, so MDS and data service are the same machine.
- **It is a trusted-network service.** The data service listens on its own port
  with no transport security of its own; anyone who can reach that port gets
  what the exports resolve. Put it behind the same boundary as nfsd.
- **AUTH_UNIX only.** A kerberos mount is offered no layout and behaves as
  ordinary NFS. This is deliberate: the alternative was serving a `sec=krb5`
  export over AUTH_UNIX.
- **Every client needs the patched kernel**, and the bcachefs module has to
  match the kernel it was built against.

## Documentation

| | |
|---|---|
| [`doc/design.md`](doc/design.md) | the interfaces, the data path, and the decisions |
| [`doc/security.md`](doc/security.md) | the security shape of the data service - read this first |
| [`doc/development.md`](doc/development.md) | repository layout, the edit/boot loop, the test bed, environment traps |
| [`doc/gotchas.md`](doc/gotchas.md) | what only showed up by running it |
| [`TODO.md`](TODO.md) | what is left, and how ready this is |

## Repository layout

```
flake.nix              modules, packages and checks
nix/                   the kernel patch, the module build, the NixOS modules, the tests
dev/                   the edit/boot loop and the patch generators
doc/, TODO.md          documentation
linux/                 the kernel checkout (its own repository, not tracked here)
bcachefs-tools/        the backend checkout (its own repository, not tracked here)
CHECKOUTS              which revisions of those two the patches were made against
```

`linux/` and `bcachefs-tools/` are separate checkouts; the patches under
`nix/patches/` are generated from them by `dev/mkpatch.sh` and
`dev/mkpatch-tools.sh`, and `CHECKOUTS` records what they were generated
against. This repository without those checkouts is the product; with them it is
the development tree.

## License

GPL-2.0, matching the kernel and `bcachefs-tools`, whose code the patches are
derived from.
