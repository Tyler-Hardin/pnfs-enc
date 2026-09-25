# Standalone NixOS test for the pNFS encoded-extent layout type, btrfs backend.
#
# Run it with dev/run-nixos-test.sh, or as the flake check of the same name.
# PROFILE picks the link and the disk from nix/tests/profiles.nix; the default,
# `lan`, is the test bed as it is (doc/development.md).
#
# What it builds: the 6.18 LTS kernel (6.18.50) with the encoded-extent layout
# patch applied and only that layout type compiled in. The other pNFS layout
# types are off so the client has exactly one to choose from, which is what lets
# the test say "the client negotiated our layout type" at all. btrfs is built in
# and registers its zstd codec.
#
# What it checks, in order:
#
#   1. the patched kernel boots with the client layout driver registered (its
#      debugfs directory exists), the server's layout ops linked in, and the
#      encoded-extent data service listening on its port;
#   2. a client read of a file on a compressed btrfs export negotiates our
#      layout and reads through the data service, and the data is right;
#   3. the layout carried the filesystem's own encoded-extent ceiling and
#      alignment, per inode, so the client can size requests without a round
#      trip (the MDS is the data service here);
#   4. the refusals the design promises fall back to the MDS - a handle outside
#      the export, a uid that may not read the file, and a security flavor the
#      export does not offer - each with a positive control;
#   5. writes through the layout, both writeback shapes, and the stability the
#      client asks for against what the service reports;
#   6. the codec table decides: an extent whose compression the filesystem does
#      not register is refused and read through the MDS;
#   7. two clients stay coherent, including a held delegation and an NFSv3
#      reader that cannot use the layout;
#   8. throughput down both paths, the concurrency shapes production has, a
#      unit whose reply is most of the wire limit, durability across a server
#      crash, and the failure modes (an unreachable service and ENOSPC).

{ pkgs, lib, profile ? "lan" }:

let
  # The machine this run is about. A name that is not in the table should fail
  # where it is written, not as a missing attribute inside a VM's config.
  profiles = import ./profiles.nix;
  bed =
    if builtins.hasAttr profile profiles then
      builtins.getAttr profile profiles
    else
      throw "unknown profile '${profile}'; known: ${toString (builtins.attrNames profiles)}";

  # The export disk's share of the profile, in the emulation module's option
  # names. This is where the extents the data service serves are stored.
  disk = {
    latencyMs = bed.diskLatencyMs;
    readMBps = bed.diskMBps;
    writeMBps = bed.diskMBps;
  };

  ccache = import ../../dev/ccache.nix { inherit pkgs lib; };

  # 6.18 LTS is the base: it is what the feature is developed and verified
  # against, and the patch is generated for exactly that release.
  patchedKernel = pkgs.linuxPackages.kernel.override (ccache.override // {
    kernelPatches = [
      {
        name = "pnfs-bcachefs-layout";
        patch = ../patches/pnfs-layout-6.18.patch;
      }
    ];

    # mkForce: kernel config here is a module system, and common-config.nix
    # already sets some of these (NFS_FS to a module, for one); a plain
    # redefinition is a conflict rather than an override.
    structuredExtraConfig = with lib.kernel; {
      # Server: nfsd with the bcachefs layout type and nothing else.
      NFSD = lib.mkForce yes;
      NFSD_V4 = lib.mkForce yes;
      NFSD_PNFS = lib.mkForce yes;
      NFSD_ENCODED_DS = lib.mkForce yes;
      NFSD_BCACHEFS_LAYOUT = lib.mkForce yes;
      NFSD_BLOCKLAYOUT = lib.mkForce no;
      NFSD_SCSILAYOUT = lib.mkForce no;
      NFSD_FLEXFILELAYOUT = lib.mkForce no;

      # Client: NFSv4 with the bcachefs layout driver. The stock layout
      # drivers stay as the config has them (PNFS_FILE_LAYOUT and
      # PNFS_FLEXFILE_LAYOUT are default-y and not overridable): which one a
      # client uses is decided by what the *server* advertises, and the server
      # below advertises only ours.
      NFS_FS = lib.mkForce yes;
      NFS_V4 = lib.mkForce yes;
      PNFS_BCACHEFS_LAYOUT = lib.mkForce yes;

      # The exported filesystem. Compressed extents are what the data path
      # moves, and btrfs has the encoded read/write ioctls already; bcachefs
      # needs its encoded_extent.c, which is a separate patch.
      BTRFS_FS = lib.mkForce yes;
    };
  });

  linuxPackages = pkgs.linuxPackagesFor patchedKernel;

  # A userspace client for the data service (see dsprobe.c); rpcinfo cannot
  # talk to a program that is not registered with rpcbind, and the service
  # deliberately is not.
  dsprobe = pkgs.stdenv.mkDerivation {
    name = "dsprobe";
    dontUnpack = true;
    buildPhase = ''
      $CC -O2 -Wall -o dsprobe ${../dsprobe.c} \
        -I${pkgs.libtirpc.dev}/include/tirpc \
        -L${pkgs.libtirpc}/lib -Wl,-rpath,${pkgs.libtirpc}/lib -ltirpc
    '';
    installPhase = ''
      install -Dm755 dsprobe $out/bin/dsprobe
    '';
  };

  # A userspace forger for the refusal tests: a stock client never reaches the
  # data service for anything the MDS would deny, so parity can only be tested
  # by presenting a request the MDS would not have granted - a handle for a file
  # outside the export, or credentials the inode denies.
  dsforge = import ./fixtures/dsforge.nix { inherit pkgs; };

  common = { pkgs, ... }: {
    imports = [ ./emulation.nix ./client.nix ];

    # The client the profile names, wired exactly as the bcachefs suite wires
    # it. Without this the control ran the kernel's defaults - two RPC slots and
    # 128 KB of readahead (doc/gotchas.md 27) - while the other side ran the
    # deployment's client, which is three to fourteen times of difference: any
    # comparison between the backends that does not hold the client fixed is a
    # comparison of clients.
    virtualisation.testClient = bed.client or { };

    boot.kernelPackages = linuxPackages;
    environment.systemPackages = [ pkgs.nfs-utils dsprobe dsforge pkgs.nftables ];
    networking.firewall.enable = false;

    # A node is not a core. The NixOS test default is one vCPU and 1 GiB, which
    # is fine for correctness and useless for measuring a data path: the client
    # does the codec work, the server runs nfsd, the filesystem and the data
    # service's own threads, and on one core they take turns. The numbers the
    # tests print are only about the path when both sides have cores to run on.
    virtualisation.cores = lib.mkDefault 12;
    virtualisation.memorySize = lib.mkDefault 8192;

    # The link this run is about. Half the round trip at each end, because netem
    # shapes egress and a round trip is both ends.
    virtualisation.testEmulation.link = {
      delayMs = bed.rttMs / 2;
      rateMbit = bed.rateMbit;
    };
  };
in
pkgs.testers.nixosTest {
  # The bed belongs in the name: two runs of this suite on two profiles are two
  # different machines' numbers.
  name = "pnfs-bcachefs-layout" + lib.optionalString (profile != "lan") "-${profile}";

  nodes = {
    server = { pkgs, ... }: {
      imports = [ common ];

      boot.supportedFilesystems.btrfs = true;
      environment.systemPackages = [ pkgs.btrfs-progs ];

      # One data-service thread per vCPU: the service is where the concurrency
      # of a wide workload has to be absorbed, and its default is eight, which
      # would cap a twelve-core server before the filesystem did. The parameter
      # belongs to the object the service is linked into, which is nfsd - the
      # test reads it back, because a name the kernel does not know is dropped
      # in silence and the service then runs on its default.
      boot.kernelParams = [ "nfsd.encoded_ds_nthreads=12" ];

      # The mount point has to exist before nfsd starts; the test mounts the
      # real (btrfs) filesystem at /srv below and restarts nfsd.
      systemd.tmpfiles.rules = [ "d /srv 0755 root root -" ];

      # The export disk: the same declaration as bcachefs.nix's, one disk.
      virtualisation.testEmulation.disks.pnfs-data = { size = 4096; } // disk;

      services.nfs.server.enable = true;
      services.nfs.server.exports = ''
        /srv/export *(rw,fsid=0,insecure,subtree_check,sec=sys,crossmnt,pnfs,no_root_squash)
      '';

      # 7.2.x nfsd uses nfsdcld for NFSv4 client tracking, and with no daemon
      # the first EXCHANGE_ID upcall never returns: the client's mount hangs
      # with nothing logged on either side. NixOS does not start it for us, but
      # nfs-utils ships the unit (with its own ordering), so this just enables
      # it.
      systemd.services.nfsdcld = {
        wantedBy = [ "multi-user.target" ];
        overrideStrategy = "asDropin";
      };
    };

    client = { ... }: {
      imports = [ common ];

      # Same reason as the client itself: a reader that is not the profile's is
      # measuring the bed's core count.
      virtualisation.cores = bed.clientCores or 12;
    };

    # A second client of the same export. Coherence between clients is the one
    # property a single client cannot test, and the data path bypasses nfsd's
    # own coherence machinery, so this is the only thing that can show it.
    client2 = { ... }: {
      imports = [ common ];
      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
    };
  };

  testScript = ''
    # What machine this run is about. The numbers below are only about that.
    print("bed: profile ${profile} - ${bed.description}")
    print("bed: rtt ${toString bed.rttMs} ms per round trip, "
          "link ${toString bed.rateMbit} Mbit/s per egress, "
          "disk ${toString bed.diskLatencyMs} ms / ${toString bed.diskMBps} MB/s")

    def counter(name):
        return int(client.succeed("cat /sys/kernel/debug/pnfs_bcachefs/%s" % name))

    def ds_counter(name):
        return int(server.succeed("cat /sys/kernel/debug/encoded_ds/%s" % name))

    start_all()

    # The client can come up without a route for a moment, and everything below
    # talks to the server across the test VLAN.
    client.wait_until_succeeds("ping -c1 -w1 server", timeout=120)

    # KVM or emulated? The VM command is `-machine accel=kvm:tcg`, so a machine
    # without /dev/kvm runs these VMs under TCG without saying anything, and
    # every throughput number below changes meaning. Logged, not asserted: a
    # KVM-less machine should still be able to run the test.
    for name, m in (("server", server), ("client", client)):
        rc, out = m.execute("systemd-detect-virt")
        m.log("%s virt: %s (rc=%d)" % (name, out.strip(), rc))

    # If the config did not take, this is the clearest failure available: the
    # ops table missing means no export advertises our layout type.
    server.succeed("grep -qw bc_layout_ops /proc/kallsyms")

    # --- server: a compressed btrfs export -------------------------------
    server.succeed("mkfs.btrfs -f -L pnfsdata /dev/mapper/pnfs-data")
    # Mount at /srv, not at the export point: the subtree test needs a file on
    # the same filesystem but outside the export.
    server.succeed("mount -o compress=zstd:1 /dev/mapper/pnfs-data /srv")
    server.succeed("mkdir -p /srv/export")
    server.succeed("chmod 0777 /srv/export")
    server.succeed("head -c 4194304 /dev/urandom > /srv/export/random.bin")
    # Same filesystem as the export, outside it, and compressed: a handle for
    # this file is exactly what the subtree check has to refuse.
    server.succeed("dd if=/dev/zero of=/srv/outside.bin bs=1M count=4 2>/dev/null")
    # Root-only, so a data-service request presenting another uid must be
    # refused by the per-file permission check.
    server.succeed("dd if=/dev/zero of=/srv/export/rootonly.bin bs=1M count=4 2>/dev/null")
    server.succeed("chmod 0600 /srv/export/rootonly.bin")
    server.succeed("sync")
    # btrfs reports st_blocks and FIEMAP lengths as logical sizes, so neither
    # stat nor `btrfs filesystem du` says anything about compression; the Data
    # profile's used bytes do.
    data_used = lambda: int(server.succeed(
        "btrfs filesystem df -b /srv/export | grep '^Data'"
    ).split("used=")[1].split(",")[0])
    used_before = data_used()
    server.succeed("dd if=/dev/zero of=/srv/export/zeros.bin bs=1M count=4 2>/dev/null")
    server.succeed("sync")
    used_after = data_used()
    server.log("data used before/after 4 MiB of zeros: %d -> %d" %
               (used_before, used_after))

    server.succeed("systemctl restart nfs-server.service")
    server.wait_for_unit("nfs-server.service")
    server.succeed("exportfs -v")
    server.log("nfsd threads:\n" + server.succeed("cat /proc/fs/nfsd/threads 2>&1"))

    # --- client: mount, then read ----------------------------------------
    client.succeed("mkdir -p /mnt")
    # Prove the client can reach nfsd's port at all: nfsd does not serve our
    # program, so this must get a reply (and fail with PROG_UNAVAIL) rather
    # than time out. If it times out, the problem is below NFS.
    rc, out = client.execute("timeout 20 dsprobe server 2049 null 2>&1")
    client.log("client->2049 probe rc=%d out=%s" % (rc, out))

    # Bounded and verbose, with short RPC timeouts: a hung mount must fail the
    # test with output instead of waiting out the harness. If the first form
    # fails, the alternatives say whether it is the version, the layout type,
    # or the export path.
    mounted = False
    for opts, target in [
        ("vers=4.1,timeo=20,retrans=2,write=lazy", "server:/"),
        ("vers=4.0,timeo=20,retrans=2", "server:/"),
        ("vers=4.1,timeo=20,retrans=2,write=lazy", "server:/srv/export"),
    ]:
        rc, out = client.execute(
            "timeout 60 mount -v -t nfs4 -o %s %s /mnt 2>&1" % (opts, target))
        client.log("mount [%s %s] rc=%d out=%s" % (opts, target, rc, out))
        if rc == 0:
            mounted = True
            break
    if not mounted:
        server.log("nfsd stats:\n" + server.succeed("cat /proc/net/rpc/nfsd 2>&1 | head -14"))
        client.log("client dmesg:\n" + client.succeed("dmesg | tail -60 2>&1 || true"))
    assert mounted, "NFS mount failed (see logs)"
    client.succeed("mountpoint -q /mnt")
    client.succeed("mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug")

    # The second client is only needed for the coherence section, but it comes
    # up here so that a mount problem is one clear failure rather than a
    # confusing one later.
    client2.wait_until_succeeds("ping -c1 -w1 server", timeout=120)
    client2.succeed("mkdir -p /mnt")
    client2.wait_until_succeeds(
        "mount -t nfs4 -o vers=4.1,timeo=20,retrans=2,write=lazy server:/ /mnt",
        timeout=300)
    client2.succeed("mountpoint -q /mnt")

    # The driver only creates this if it registered the layout type.
    client.succeed("test -d /sys/kernel/debug/pnfs_bcachefs")

    for name in ("random.bin", "zeros.bin"):
        digest = server.succeed("sha256sum /srv/export/%s" % name).split()[0]
        rc, out = client.execute(
            "echo '%s  /mnt/%s' | sha256sum -c - 2>&1" % (digest, name))
        client.log("read %s rc=%d out=%s" % (name, rc, out))
        if rc != 0:
            client.log("client pnfs counters on failure: lseg_alloc=%d "
                       "lseg_alloc_err=%d read_pagelist=%d unit_max=%d "
                       "unit_align=%d layout_codecs=%d codec_missing=%d" %
                       (counter("lseg_alloc"), counter("lseg_alloc_err"),
                        counter("read_pagelist"), counter("unit_max"),
                        counter("unit_align"), counter("layout_codecs"),
                        counter("codec_missing")))
            client.log("client dmesg:\n" + client.succeed("dmesg | tail -50 2>&1 || true"))
            server.log("server nfsd stats:\n" +
                       server.succeed("cat /proc/net/rpc/nfsd 2>&1 | head -14"))
        assert rc == 0, "read of %s failed: %s" % (name, out)

    # --- the data service: started by the first layout, and talking -------
    server.succeed("mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug")
    # Only created if encoded_ds_start() ran and bound its listeners.
    server.succeed("test -d /sys/kernel/debug/encoded_ds")
    # ... and running the threads it was asked for. A parameter the kernel does
    # not know is ignored without a word, and the service then runs on its
    # default of eight, which is where a wide workload would quietly cap.
    assert int(server.succeed(
        "cat /sys/module/nfsd/parameters/encoded_ds_nthreads")) == 12, \
        "the data service is not running the threads the test asked for"
    server.succeed("dsprobe 127.0.0.1 2050 null")
    # ... and reachable from the client, which is the whole point of it.
    client.succeed("dsprobe server 2050 null")

    # --- the layout, and the client's view of it -------------------------
    lseg = counter("lseg_alloc")
    assert lseg >= 1, "client never negotiated a layout (lseg_alloc=%d)" % lseg
    assert counter("lseg_alloc_err") == 0, "client failed to decode the layout body"
    rp = counter("read_pagelist")
    assert rp >= 1, "client never reached the pnfs read path (read_pagelist=%d)" % rp

    # The layout carried the server filesystem's own encoded-extent limits:
    # the MDS is the data service, so these are its per-inode values and the
    # client did not have to ask for them. btrfs's ceiling is 128 KiB and its
    # alignment is the filesystem sector size.
    umax = counter("unit_max")
    assert umax == 131072, "layout carried unit_max=%d, expected BTRFS_MAX_COMPRESSED" % umax
    ualign = counter("unit_align")
    assert ualign == 4096, "layout carried unit_align=%d, expected the btrfs sectorsize" % ualign

    # ... and the codecs it may serve extents with, which is the ownership
    # boundary: the layout names them and the client resolves each name to a
    # local implementation, so the exporting filesystem's codec numbering never
    # crosses the wire and a codec this client does not have is a hole in this
    # list rather than a number it would have to guess at.
    lc = counter("layout_codecs")
    assert lc >= 1, "the layout named no codecs (layout_codecs=%d)" % lc
    assert counter("codec_missing") == 0, \
        "the client could not resolve %d of the %d codecs the layout named" % \
        (counter("codec_missing"), lc)
    wc = counter("write_codec")
    assert 0 <= wc < lc, \
        "writes would use codec position %d of %d: no codec to encode with" % (wc, lc)
    # Nothing was asked of modprobe here: btrfs is built in, so the codec the
    # layout names was registered before the first layout arrived and the first
    # lookup found it. The on-demand path is tested by the bcachefs test, where
    # the provider is a module the client does not have.
    assert counter("codec_requests") == 0, \
        "the client asked for a codec provider it already had (%d requests)" % \
        counter("codec_requests")

    # The client asked the data service to read both files: zeros.bin is stored
    # compressed, so its units come back and are decoded; random.bin is stored
    # plain, so the service refuses it (-ENODATA) and the request goes through
    # the MDS. The server's own counters have to agree with the client's, which
    # is what makes this a test of the wire rather than of the client.
    server.succeed("mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug")
    drok, drerr = counter("ds_read_ok"), counter("ds_read_err")
    drne = counter("ds_read_not_encoded")
    sread, srne = ds_counter("read"), ds_counter("not_encoded")
    io_read = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    server.log("encoded read: client read_ok=%d read_err=%d not_encoded=%d "
               "last_err=%d unit_len=%d payload_len=%d; server read=%d "
               "not_encoded=%d; nfsd bytes read=%d" %
               (drok, drerr, drne, counter("ds_last_read_err"),
                counter("ds_last_unit_len"), counter("ds_last_payload_len"),
                sread, srne, io_read))
    assert drok >= 1, \
        "the encoded read never completed (read_ok=%d read_err=%d last_err=%d)" % \
        (drok, drerr, counter("ds_last_read_err"))
    assert drerr == 0, "encoded read errors: %d (last %d)" % \
        (drerr, counter("ds_last_read_err"))
    assert drne >= 1, \
        "the uncompressed file was not refused by the service (not_encoded=%d)" % drne
    assert sread >= drok, "server served %d reads for %d client completions" % (sread, drok)
    assert srne >= 1, "the server never refused a range as unencoded"
    # The zstd extents translated cleanly through the codec table; the one case
    # that must not is exercised at the end of the test.
    assert ds_counter("codec_unknown") == 0, \
        "the server could not map a codec for an extent it served"
    # zeros.bin's 4 MiB must not have come through the MDS: with the encoded
    # path working, nfsd reads the incompressible file plus a few fallback units
    # and nothing more.
    assert io_read < 6 * 1024 * 1024, \
        "nfsd read %d bytes: zeros.bin did not come from the data service" % io_read

    # --- parity: the data service refuses what the MDS would ---------------
    # A stock mount never reaches the data service for anything the MDS denies,
    # so the refusals are only observable from a request the MDS would not have
    # granted. dsforge sends one, using a file handle the kernel actually handed
    # out (from the client's layout) and credentials of our choosing.
    def layout_dump():
        out = client.succeed("cat /sys/kernel/debug/pnfs_bcachefs/layout_fh")
        d = dict(l.split(None, 1) for l in out.strip().splitlines())
        return d["fh"].strip()

    # Reading zeros.bin fetches a layout, and the dump is the last one fetched.
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    client.succeed("dd if=/mnt/zeros.bin of=/dev/null bs=1M 2>/dev/null")
    fh = layout_dump()
    client.log("layout handle: fh_len=%d" % (len(fh) // 2))
    assert len(fh) >= 32, "no usable layout handle was dumped"

    # Positive control: the handle exactly as handed out is served, which is
    # what makes the refusals below meaningful rather than a malformed request.
    out = client.succeed("dsforge -f %s server 2050 probe" % fh)
    client.log("dsforge probe (real handle): %s" % out.strip())
    assert "status=0" in out, "the real layout handle was refused: %s" % out

    # Subtree containment: the export's fsid, a fid for a file outside it. The
    # MDS refuses this handle (nfsd_acceptable); the DS must too, or a client
    # that invents a handle reaches the whole filesystem.
    fid = server.succeed("dsforge fid /srv/outside.bin").split()
    out = client.succeed("dsforge -f %s -F %s -y %s server 2050 probe"
                         % (fh, fid[3], fid[1]))
    client.log("dsforge probe (outside the export): %s" % out.strip())
    assert "status=-116" in out, \
        "a handle for a file outside the export was not refused: %s" % out

    # Per-file permission: a root-only inode, a request presenting uid 1000.
    client.succeed("dd if=/mnt/rootonly.bin of=/dev/null bs=1M 2>/dev/null")
    fh = layout_dump()
    out = client.succeed("dsforge -f %s -u 1000 -g 1000 server 2050 probe" % fh)
    client.log("dsforge probe (uid 1000 on a root-only file): %s" % out.strip())
    assert "status=-13" in out, \
        "a request with credentials the inode denies was not refused: %s" % out

    # Security flavor: this export offers sec=sys only, so AUTH_NULL is the
    # wrong flavor and fh_verify refuses it - the same answer the MDS gives.
    out = client.succeed("dsforge -a null -f %s server 2050 probe" % fh)
    client.log("dsforge probe (AUTH_NULL against sec=sys): %s" % out.strip())
    assert "status=-13" in out, \
        "an AUTH_NULL request was not refused: %s" % out

    # Read-only exports are not tested here: a read-only export has to be a
    # separate export, and a second export on the same filesystem is not
    # reachable by the client (nfsd serves the subdirectory from the parent
    # export; NFSEXP_NOHIDE only governs mountpoint crossing). A read-only
    # export on a second filesystem would test it, and is the obvious next
    # addition. The read-only check itself lives in nfsd_permission(), which the
    # uid case above already exercises.

    server.log("DS after the forged requests: read=%d errors=%d not_encoded=%d "
               "codec_unknown=%d" %
               (ds_counter("read"), ds_counter("errors"),
                ds_counter("not_encoded"), ds_counter("codec_unknown")))

    # A rough throughput comparison between the two paths, 4 MiB each.
    # Absolute numbers in a VM mean little, but the ratio is what the
    # asynchronous conversion is for: encoded units are several in flight, and
    # the data service sends a compressed payload rather than 4 MiB of
    # plaintext. (Not the same file: NFSv4.0 is not enabled in this kernel, so
    # there is no way to force the same file down the MDS path here.)
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    enc_rate = client.succeed(
        "dd if=/mnt/zeros.bin of=/dev/null bs=1M 2>&1 | tail -1")
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    mds_rate = client.succeed(
        "dd if=/mnt/random.bin of=/dev/null bs=1M 2>&1 | tail -1")
    client.log("4 MiB read: encoded data service (compressed file): %s" %
               enc_rate.strip())
    client.log("4 MiB read: MDS (incompressible file):              %s" %
               mds_rate.strip())

    # --- client: write through the layout ---------------------------------
    # Compressible data, so the encoded write path engages. An incompressible
    # 128 KiB unit does not fit in an encoded unit of the same size and falls
    # back, which is correct but would not exercise the data service.
    client.succeed("dd if=/dev/zero of=/mnt/from-client.bin bs=1M count=4 2>/dev/null")
    client.succeed("sync")
    server.succeed("sync")

    cdigest = client.succeed("sha256sum /mnt/from-client.bin").split()[0]
    sdigest = server.succeed("sha256sum /srv/export/from-client.bin").split()[0]
    assert cdigest == sdigest, "client write did not reach the server intact"
    # ... and the file has to be there to be hashed: an empty file hashes the
    # same on both sides, which is exactly how a write that extended nothing
    # would pass the check above.
    ssize = int(server.succeed("stat -c %s /srv/export/from-client.bin"))
    assert ssize == 4194304, \
        "the server sees a %d-byte file: the write did not extend it" % ssize
    wp = counter("write_pagelist")
    assert wp >= 1, "client never reached the pnfs write path (write_pagelist=%d)" % wp
    assert counter("lseg_alloc_err") == 0

    wok, werr = counter("ds_write_ok"), counter("ds_write_err")
    wlast, swr = counter("ds_last_write_err"), ds_counter("write")
    server.log("encoded write: client write_ok=%d write_err=%d last_err=%d; "
               "server write=%d; nfsd bytes written=%d" %
               (wok, werr, wlast, swr,
                int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[2])))
    assert wok >= 1, \
        "the encoded write never completed (write_ok=%d write_err=%d last_err=%d)" % \
        (wok, werr, wlast)
    assert werr == 0, "encoded write errors: %d (last %d)" % (werr, wlast)
    assert swr >= 1, "the server never served an encoded write"

    # A write through the data service marks the inode for a layout commit, and
    # a flush of the file is where the client acts on that; the server's
    # proc_layoutcommit is where the two views of the file meet.
    synced = counter("sync")
    server.log("layout sync calls after the write: %d" % synced)
    assert synced >= 1, "the client never reached the layout commit path"

    # --- durability: what the client asks for, and what it is told --------
    # Two writeback shapes, both of which the data service has to answer
    # honestly. Ordinary background writeback asks for nothing
    # (nfs_pgio_rpcsetup leaves args.stable = NFS_UNSTABLE), so the service
    # must say UNSTABLE and the client must commit through the MDS; a
    # fsync-driven writeback asks for FILE_SYNC (FLUSH_COND_STABLE with
    # nothing waiting to commit, which the mount's write=lazy keeps), so the
    # backend has to sync the unit and say so.
    def write_verf():
        return client.succeed(
            "cat /sys/kernel/debug/pnfs_bcachefs/write_verf").strip()

    # (a) background writeback: unstable, and honestly reported as such.
    client.succeed("sysctl -qw vm.dirty_expire_centisecs=1 vm.dirty_writeback_centisecs=1")
    stable0, filesync0 = counter("ds_write_stable"), counter("ds_write_file_sync")
    srv_unstable0 = ds_counter("write_unstable")
    wok_before_flush = counter("ds_write_ok")
    client.succeed("dd if=/dev/zero of=/mnt/unstable.bin bs=1M count=4 2>/dev/null")
    # Nothing syncs here: the kernel's own flusher sends it, which is the shape
    # that asks for nothing. Two things say it got there - the data service saw
    # the writes, and the file reached its full size on the server, the second
    # being what says an encoded write extended the file rather than leaving a
    # hole with the data behind it.
    client.wait_until_succeeds(
        "test $(cat /sys/kernel/debug/pnfs_bcachefs/ds_write_ok) -gt %d"
        % wok_before_flush, timeout=120)
    server.wait_until_succeeds(
        "test $(stat -c %s /srv/export/unstable.bin) -eq 4194304", timeout=120)
    client.wait_until_succeeds(
        "test $(cat /sys/kernel/debug/pnfs_bcachefs/ds_last_committed) -eq 0",
        timeout=60)
    verf_before_crash = write_verf()
    client.log("background writeback: stable %d -> %d, file-sync %d -> %d, "
               "last committed %d, verf %s; server unstable %d -> %d" %
               (stable0, counter("ds_write_stable"), filesync0,
                counter("ds_write_file_sync"), counter("ds_last_committed"),
                verf_before_crash, srv_unstable0, ds_counter("write_unstable")))
    assert counter("ds_write_stable") == stable0, \
        "a background writeback asked the data service to sync"
    assert counter("ds_write_file_sync") == filesync0, \
        "the data service reported a durability the write did not ask for"
    assert ds_counter("write_unstable") > srv_unstable0, \
        "the server did not report the write as unstable"
    assert verf_before_crash != "0" * 16, \
        "the data service returned no write verifier"

    # The commit that follows must not redirty anything, and it has to be a
    # file-level one. sync(2) is not a durability barrier for NFS: there is no
    # ->sync_fs, and the async flusher usually writes the pages out unstably
    # before the sync writeback reaches them. fdatasync(2) is the barrier - it
    # writes back and then COMMITs - and the client only drops the pages when
    # the commit reply's verifier matches the one the write carried, which is
    # the only reason that value crosses the wire.
    client.succeed("sync -d /mnt/unstable.bin")
    wok_committed = counter("ds_write_ok")
    client.succeed("sync -d /mnt/unstable.bin")
    assert counter("ds_write_ok") == wok_committed, \
        "a commit redirtied and rewrote pages: the write verifier did not match"

    # (b) an fsync-driven writeback: the service is asked to sync, and does.
    # Three things have to line up for the client to ask at all. The mount is
    # write=lazy, so nfs_writepages() derives the stable level from the
    # writeback (FLUSH_COND_STABLE) instead of dropping it; the range fits in
    # one pgio, because a writeback that spans more than one sets pg_moreio and
    # nfs_generic_pgio() clears FLUSH_COND_STABLE for it; and the unit is a
    # normal one, not a single block, because a backend may refuse a payload
    # that cannot be padded smaller than the unit it describes (bcachefs does:
    # its framing pads to the block size, so a one-block unit has nothing
    # left to shrink). With all three, and nothing waiting to commit, the
    # level is FILE_SYNC and the backend has to sync the unit before it may
    # answer that it did.
    client.succeed("sysctl -qw vm.dirty_expire_centisecs=600000 vm.dirty_writeback_centisecs=1")
    stable1, filesync1 = counter("ds_write_stable"), counter("ds_write_file_sync")
    srv_filesync1 = ds_counter("write_file_sync")
    client.succeed("dd if=/dev/zero of=/mnt/file-sync.bin bs=65536 count=1 conv=fsync 2>/dev/null")
    client.log("fsync-driven writeback: stable %d -> %d, file-sync %d -> %d, "
               "last committed %d, verf %s; server file-sync %d -> %d" %
               (stable1, counter("ds_write_stable"), filesync1,
                counter("ds_write_file_sync"), counter("ds_last_committed"),
                write_verf(), srv_filesync1, ds_counter("write_file_sync")))
    assert counter("ds_write_stable") > stable1, \
        "an fsync-driven writeback did not ask for a durable write"
    assert counter("ds_write_file_sync") > filesync1, \
        "the data service did not honour a FILE_SYNC write"
    assert counter("ds_last_committed") == 2, \
        "the last write reported committed=%d, expected FILE_SYNC" % \
        counter("ds_last_committed")
    assert ds_counter("write_file_sync") > srv_filesync1, \
        "the server did not record a FILE_SYNC write"
    assert write_verf() == verf_before_crash, \
        "the write verifier changed within one server session"

    # --- the file the encoded path will move is actually encoded ----------
    # Last, so a failure here cannot hide the counters above. 4 MiB of zeros
    # that really went through zstd is a few KiB of Data profile, not 4 MiB.
    delta = used_after - used_before
    assert delta < 1048576, \
        "4 MiB of zeros grew the Data profile by %d bytes: compression did not take" % delta

    # --- a codec the exporting filesystem stores but does not register -----
    # The authority over what is served encoded is the codec table, not the
    # backend's numbering: btrfs stores zlib extents too, and its numbering for
    # zlib is a perfectly valid descriptor value, but no zlib codec is
    # registered, so those extents must come back as "not served encoded" and
    # the read must fall through to the MDS intact. Without this the table
    # would be decorative - the zstd case cannot tell a real lookup from a
    # hardcoded answer.
    io_before = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    # The per-inode property, so only this file is zlib and the export's mount
    # options are untouched.
    server.succeed("touch /srv/export/zlib.bin")
    server.succeed("btrfs property set /srv/export/zlib.bin compression zlib")
    # It has to have taken, or the file is stored uncompressed and the extent
    # would be refused before any codec is consulted - which would make this
    # block pass without testing the table at all.
    prop = server.succeed("btrfs property get /srv/export/zlib.bin compression")
    server.log("zlib.bin compression property: %s" % prop.strip())
    assert "zlib" in prop, "the compression property did not take: %s" % prop
    zused_before = data_used()
    server.succeed("dd if=/dev/zero of=/srv/export/zlib.bin bs=1M count=4 2>/dev/null")
    server.succeed("sync")
    zused_after = data_used()
    # The Data profile is the only view that sees compression (st_blocks and
    # FIEMAP lengths are logical), so this is what says the extent really is
    # zlib on disk rather than 4 MiB of stored zeros.
    server.log("4 MiB of zlib zeros grew the Data profile by %d bytes" %
               (zused_after - zused_before))
    assert zused_after - zused_before < 1048576, \
        "zlib.bin stored %d bytes of Data: it is not compressed" % \
        (zused_after - zused_before)
    zdigest = server.succeed("sha256sum /srv/export/zlib.bin").split()[0]
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    rc, out = client.execute(
        "echo '%s  /mnt/zlib.bin' | sha256sum -c - 2>&1" % zdigest)
    client.log("read zlib.bin rc=%d out=%s" % (rc, out))
    assert rc == 0, "read of the zlib file failed: %s" % out
    io_after = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])

    cunk = ds_counter("codec_unknown")
    client.log("zlib extent: server codec_unknown=%d, client not_encoded=%d, "
               "nfsd read %d -> %d bytes" %
               (cunk, counter("ds_read_not_encoded"), io_before, io_after))
    assert cunk >= 1, \
        "the zlib extent was not refused by the codec table (codec_unknown=%d): " \
        "the table is not what decides" % cunk
    # Refused means it read the file through the MDS instead, all 4 MiB of it.
    assert io_after - io_before >= 4 * 1024 * 1024, \
        "nfsd read only %d bytes for a refused extent: it did not fall back" % \
        (io_after - io_before)

    # --- coherence: a second client ---------------------------------------
    # The data path bypasses nfsd entirely - an encoded write never touches the
    # MDS's open, its page cache or its leases - so the only things keeping two
    # clients of one export coherent are the change attribute a client checks
    # on close-to-open, and the lease nfsd breaks when someone else writes.
    # Both now have to cover a path that does not go through nfsd, which is
    # what this measures: client writes through the layout, client2 reads.
    def sha256_on(m, path):
        return m.succeed("sha256sum %s" % path).split()[0]

    def pattern(size, byte, path):
        # Compressible (the encoded write path needs something the codec can
        # shrink) and different per byte, so the two clients can tell the
        # contents apart. head/tr rather than `yes | head`: the driver's shell
        # has pipefail on and yes's SIGPIPE would fail the command.
        return "head -c %d /dev/zero | tr '\\000' '%s' > %s" % (size, byte, path)

    def overwrite(size, byte, path):
        # The same size, written in place, with no truncate. An O_TRUNC write is
        # a SETATTR the MDS handles, and that updates the attributes on its own;
        # this is the write that only the data path touches, so what the
        # attributes look like afterwards is the encoded write's doing.
        return ("head -c %d /dev/zero | tr '\\000' '%s' > /tmp/pat && "
                "dd if=/tmp/pat of=%s bs=65536 conv=notrunc 2>/dev/null"
                % (size, byte, path))

    def disk_digest(path):
        # What is actually stored, not what the server happens to have cached:
        # a server-side read of a range the data service has just written can
        # hand back stale folios - which is one of the things this section is
        # about - so the expected digest has to come from the disk.
        server.succeed("echo 3 > /proc/sys/vm/drop_caches")
        return sha256_on(server, path)

    def attrs(m, path):
        # mtime and ctime with nanoseconds, as that node sees them: the change
        # attribute nfsd hands out is derived from the server's ctime for this
        # filesystem, so these are the numbers the second client's
        # close-to-open check turns on - and one-second granularity hides a
        # write that lands in the same second as the read before it.
        return m.succeed("stat -c '%%y %%z' %s" % path).strip()

    def c2_ds_reads():
        # Whether client2's read went to the data service or came out of its
        # page cache, which is what says whether it revalidated at all.
        return int(client2.succeed(
            "cat /sys/kernel/debug/pnfs_bcachefs/ds_read_ok"))

    server.succeed(pattern(1048576, "A", "/srv/export/coherence.bin"))
    server.succeed("sync")
    sdigest = disk_digest("/srv/export/coherence.bin")
    # Cache it on client2 first, or every read below is a first read.
    assert sha256_on(client2, "/mnt/coherence.bin") == sdigest, \
        "client2's first read of the coherence file is already wrong"

    # (1) a write through the layout that changes the size: the case a client
    # can catch from the attributes alone.
    client.succeed(pattern(2097152, "B", "/mnt/coherence.bin"))
    client.succeed("sync -d /mnt/coherence.bin")
    sdigest = disk_digest("/srv/export/coherence.bin")
    c2 = sha256_on(client2, "/mnt/coherence.bin")
    client.log("coherence (size changed): server=%s client2=%s" %
               (sdigest[:16], c2[:16]))
    assert c2 == sdigest, \
        "client2 served a stale copy after a write that changed the size"

    # (2) the same size and different content, so only the change attribute can
    # tell client2 that what it cached is gone. This is the close-to-open
    # promise, and the case a data-service write has to make visible.
    # Control: client2 has to actually cache this file, or a "fresh" read
    # below means nothing. Two reads in a row must cost one round of reads.
    before = (attrs(server, "/srv/export/coherence.bin"),
              attrs(client2, "/mnt/coherence.bin"), c2_ds_reads())
    sha256_on(client2, "/mnt/coherence.bin")
    r0 = c2_ds_reads()
    sha256_on(client2, "/mnt/coherence.bin")
    r1 = c2_ds_reads()
    assert r1 == r0, \
        "the second read of an unchanged file went to the data service: " \
        "this client does not cache, so nothing below is a test"
    client.log("coherence: v4.1 cache control: ds_reads %d -> %d -> %d" %
               (before[2], r0, r1))
    client.succeed(overwrite(2097152, "C", "/mnt/coherence.bin"))
    client.succeed("sync -d /mnt/coherence.bin")
    sdigest = disk_digest("/srv/export/coherence.bin")
    c2 = sha256_on(client2, "/mnt/coherence.bin")
    client.log("coherence (same size, different content): server=%s client2=%s; "
               "before: server=[%s] client2=[%s] ds_reads=%d; after: server=[%s] "
               "client2=[%s] ds_reads=%d" %
               (sdigest[:16], c2[:16], before[0], before[1], before[2],
                attrs(server, "/srv/export/coherence.bin"),
                attrs(client2, "/mnt/coherence.bin"), c2_ds_reads()))
    assert c2 == sdigest, \
        "client2 served a stale same-size copy: the change attribute did not move"

    # (3) a held delegation. A delegation is a promise that the holder hears
    # about a change before it happens. nfsd will not grant one on a file that
    # has already seen a conflicting open, so this needs its own file, opened
    # by client2 first, and the states file names the file it is for.
    def delegations(name):
        out = server.succeed(
            "grep -h 'type: deleg' /proc/fs/nfsd/clients/*/states || true")
        return [l for l in out.splitlines() if name in l]

    server.succeed(pattern(1048576, "F", "/srv/export/deleg.bin"))
    server.succeed("sync")
    client2.succeed("setsid sh -c 'exec 3</mnt/deleg.bin; sleep 900' "
                    ">/dev/null 2>&1 &")
    # The open, its OPEN RPC and nfsd's grant are asynchronous, so checking
    # once right after the open is a race - and one a loaded test machine
    # loses. Wait for the grant rather than for a fixed time.
    held = []
    for _ in range(60):
        held = delegations("deleg.bin")
        if held:
            break
        client2.execute("sleep 1")
    client.log("coherence: delegations on deleg.bin before the write: %s" %
               (held or "none"))
    assert held, "the server granted client2 no delegation on deleg.bin"
    # Cache it under the delegation, then let client1 rewrite the file through
    # the layout.
    sha256_on(client2, "/mnt/deleg.bin")
    client.succeed(pattern(2097152, "G", "/mnt/deleg.bin"))
    client.succeed("sync -d /mnt/deleg.bin")
    sdigest = disk_digest("/srv/export/deleg.bin")
    after = delegations("deleg.bin")
    c2 = sha256_on(client2, "/mnt/deleg.bin")
    client.log("coherence (delegation held): server=%s client2=%s, "
               "delegations after the write: %s" %
               (sdigest[:16], c2[:16], after or "none"))
    assert not after or c2 == sdigest, \
        "client2 kept a delegation across a data-service write and served " \
        "stale data: the write went around the lease"

    # (5) the same promise for a client that cannot use the layout at all: an
    # NFSv3 mount. It has no layout for anyone to recall, so nothing but the
    # attributes (mtime and size, for v3) can tell it that its cached copy is
    # gone - and the layout recall that masked the same-size case above cannot
    # happen. This is the client the stale change attribute would actually hurt.
    client2.succeed("mkdir -p /mnt3")
    client2.wait_until_succeeds(
        "mount -t nfs -o vers=3,nolock,timeo=20,retrans=2 server:/srv/export /mnt3",
        timeout=300)
    sdigest = disk_digest("/srv/export/coherence.bin")
    assert sha256_on(client2, "/mnt3/coherence.bin") == sdigest, \
        "client2's first read of the v3 mount is already wrong"
    # Control first: the v3 client has to cache, or a fresh read below means
    # nothing either.
    io0 = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    sha256_on(client2, "/mnt3/coherence.bin")
    ioA = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    sha256_on(client2, "/mnt3/coherence.bin")
    ioB = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    assert ioB == ioA, \
        "the second read of an unchanged file went to the server: this " \
        "client does not cache, so nothing below is a test"
    client.log("coherence: v3 cache control: nfsd read %d -> %d -> %d bytes" %
               (io0, ioA, ioB))
    before = attrs(server, "/srv/export/coherence.bin")
    io0 = ioB
    client.succeed(overwrite(2097152, "H", "/mnt/coherence.bin"))
    client.succeed("sync -d /mnt/coherence.bin")
    sdigest = disk_digest("/srv/export/coherence.bin")
    c2 = sha256_on(client2, "/mnt3/coherence.bin")
    io1 = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    client.log("coherence (v3 reader, same size): server=%s client2=%s; "
               "server attrs %s -> %s; nfsd read %d -> %d bytes" %
               (sdigest[:16], c2[:16], before,
                attrs(server, "/srv/export/coherence.bin"), io0, io1))
    assert c2 == sdigest, \
        "an NFSv3 client served stale data after a same-size data-service " \
        "write: the attributes nfsd reports did not move"

    # (4) both clients want the file at once. A second client's LAYOUTGET
    # recalls the first client's layout (nfsd4_recall_conflict()), so this
    # exercises CB_LAYOUTRECALL on a driver that has never seen one, and both
    # clients have to keep reading correctly afterwards.
    sdigest = disk_digest("/srv/export/coherence.bin")
    reads0 = c2_ds_reads()
    d0 = sha256_on(client2, "/mnt/coherence.bin")
    d1 = sha256_on(client, "/mnt/coherence.bin")
    client.log("coherence: read back through both clients: client=%s client2=%s "
               "(server=%s); client2 ds_reads %d -> %d" %
               (d1[:16], d0[:16], sdigest[:16], reads0, c2_ds_reads()))
    assert d0 == sdigest and d1 == sdigest, \
        "a client served stale data after the layouts were recalled"
    client.succeed(pattern(2097152, "E", "/mnt/coherence.bin"))
    client.succeed("sync -d /mnt/coherence.bin")
    sdigest = disk_digest("/srv/export/coherence.bin")
    assert sha256_on(client2, "/mnt/coherence.bin") == sdigest, \
        "client2 served stale data after a write that followed a layout recall"

    # --- performance: the same file down both paths ------------------------
    # The comparison that was here used two different files - one compressed,
    # one incompressible - so it measured how much data had to move rather than
    # how the path performs. This does the same file twice: once through the
    # data service and once through an NFSv3 mount of the same export (no
    # layouts, so the MDS serves it), cold caches, direct I/O so the client's
    # page cache is not the thing being measured. The service's own RPC and
    # backend-time counters come along, because throughput alone cannot say
    # whether the cost is the round trips, the codec work, or the filesystem.
    client.succeed("mkdir -p /mnt3")
    client.wait_until_succeeds(
        "mount -t nfs -o vers=3,nolock,timeo=20,retrans=2 "
        "server:/srv/export /mnt3", timeout=300)

    server.succeed("head -c 67108864 /dev/zero | tr '\\000' 'P' > "
                   "/srv/export/perf.bin")
    server.succeed("sync")

    def rate_of(line):
        tail = line.split(",")[-1].strip().split()
        rate = float(tail[0])
        return rate * 1024 if tail[1].startswith("GB") else rate

    def perf_best(label, cmd, rpcs, repeats=3):
        best = None
        for _ in range(repeats):
            rpcs0 = ds_counter(rpcs) if rpcs else 0
            ns0 = ds_counter(rpcs + "_ns") if rpcs else 0
            pgio_ctr = "read_pagelist" if cmd.startswith("dd if=") else "write_pagelist"
            pgios0 = counter(pgio_ctr)
            out = client.succeed(
                "echo 3 > /proc/sys/vm/drop_caches; %s 2>&1" % cmd).strip()
            line = out.splitlines()[-1]
            if best is None or rate_of(line) > rate_of(best):
                best = line
                extra = ""
                if rpcs:
                    nr = max(ds_counter(rpcs) - rpcs0, 1)
                    ns = ds_counter(rpcs + "_ns") - ns0
                    extra = (" [%d RPCs, %d pgios, backend %.0f us/RPC]" %
                             (nr, counter(pgio_ctr) - pgios0,
                              ns / nr / 1000.0))
        client.log("perf %s: %s%s" % (label, best, extra))
        return rate_of(best)

    # Reads: the same 64 MiB file, the same client. Direct I/O makes the client
    # issue one request at a time, which is the worst case for a driver that
    # walks a request's units; buffered I/O lets readahead have several in
    # flight, which is how a real reader arrives.
    # The read counters either side of the DS read passes, for the structural
    # checks below: deltas, because the earlier tests in this script read
    # through the data path too.
    bytes0 = counter("ds_read_bytes")
    waste0 = counter("ds_read_wasted")
    pgio0 = counter("read_pagelist")

    assert perf_best("read DS  direct ", "dd if=/mnt/perf.bin of=/dev/null "
                     "bs=1M iflag=direct", "read") > 0
    # Buffered once, not three times: repeating the buffered read through the
    # data service used to stop the *client's* data path (doc/gotchas.md 29 and
    # 30, both fixed), and the benchmark should not be the thing that trips over
    # it.
    assert perf_best("read DS  buffered", "dd if=/mnt/perf.bin of=/dev/null "
                     "bs=1M", "read", repeats=1) > 0
    assert perf_best("read MDS direct ", "dd if=/mnt3/perf.bin of=/dev/null "
                     "bs=1M iflag=direct", None) > 0
    assert perf_best("read MDS buffered", "dd if=/mnt3/perf.bin of=/dev/null "
                     "bs=1M", None, repeats=1) > 0

    # Writes: a fresh file each time, so each run and each path creates its own
    # extents, and buffered rather than O_DIRECT - a repeated direct write
    # through the data path wedged the server in testing, which is its own bug
    # to chase and not this benchmark's job. If it was the same lost transport,
    # doc/gotchas.md 29's fix covers the write path too.
    for path in ("/mnt/perf-ds.bin", "/mnt3/perf-mds.bin"):
        client.succeed("rm -f %s" % path)
    assert perf_best("write DS ",
                     "rm -f /mnt/perf-ds.bin; "
                     "dd if=/dev/zero of=/mnt/perf-ds.bin bs=1M count=64 "
                     "conv=fsync", "write", repeats=2) > 0
    assert perf_best("write MDS",
                     "rm -f /mnt3/perf-mds.bin; "
                     "dd if=/dev/zero of=/mnt3/perf-mds.bin bs=1M count=64 "
                     "conv=fsync", None, repeats=2) > 0

    # Both write the same bytes, so they have to agree about them.
    assert sha256_on(server, "/srv/export/perf-ds.bin") == \
           sha256_on(server, "/srv/export/perf-mds.bin"), \
        "the two write paths produced different files"

    # The service answers with the whole unit an offset falls in, so a request
    # smaller than a unit fetches that unit again for every request inside it
    # and throws the rest away. The DS read passes below are four 64 MiB reads
    # (three direct, one buffered); what has to hold is that the unit bytes the
    # service handed over are about what the reads wanted - with a request
    # smaller than a unit, half of them are unwanted. Counts, not rates: the
    # shape of the traffic, not its speed. What is left is the remainder of the
    # unit each request boundary lands in, which the next request asks for again.
    got = counter("ds_read_bytes") - bytes0
    wasted = counter("ds_read_wasted") - waste0
    client.log("perf: unit_max=%d, read pgios=%d, unit bytes=%d, of which "
               "unwanted=%d (%.1f%%)" %
               (counter("unit_max"), counter("read_pagelist") - pgio0, got,
                wasted, 100.0 * wasted / max(got, 1)))
    assert got >= 4 * 64 * 1024 * 1024, \
        "fewer unit bytes than the four 64 MiB reads asked for (%d)" % got
    assert wasted * 10 < got * 3, \
        "a third of the unit bytes the service sent were unwanted (%d of %d)" % \
        (wasted, got)

    # --- concurrency: the shapes a real workload arrives in -----------------
    # Everything above moves one stream. What hurts in production is several at
    # once: writers sharing a file, readers sharing one with a writer, and many
    # streams to different files. The nodes have real core counts now - they used
    # to run every node on one vCPU, which measures the time-slicer - and the
    # client is the side that does the codec work, so it is the side with cores
    # to spare.
    #
    # Each case runs down both paths (the data service on /mnt, an NFSv3 mount of
    # the same export on /mnt3) so the numbers are comparable within the run.
    # What has to hold besides the rates: nothing fails (a wedge in the data path
    # shows up here first), the service is the one serving, and it really had
    # several calls in the backend at once.

    def mbps(nbytes, ns):
        return nbytes / 1048576.0 / (ns / 1e9)

    def timed(cmd):
        """Run @cmd on the client; the guest's shell reports its own wall time."""
        script = ("t0=$(date +%s%N); " + cmd +
                  "; t1=$(date +%s%N); echo $((t1-t0))")
        out = client.succeed(script).strip()
        return int(out.splitlines()[-1])

    nstream = 24
    smb = 16
    for i in range(nstream):
        server.succeed("head -c %d /dev/zero | tr '\\000' 'S' > "
                       "/srv/export/stream-%02d.bin" % (smb * 1048576, i))
    server.succeed("sync")
    client.succeed("ls /mnt3/stream-00.bin >/dev/null")

    def streams_read(label, dirpath, flags):
        ns = timed("for i in $(seq -w 0 %d); do dd if=%s/stream-$i.bin "
                   "of=/dev/null bs=1M %s & done; wait" % (nstream - 1, dirpath,
                                                           flags))
        rate = mbps(nstream * smb * 1048576, ns)
        client.log("conc read  %-8s %d streams x %d MiB: %.2f s, %.0f MB/s aggregate"
                   % (label, nstream, smb, ns / 1e9, rate))
        return rate

    def streams_write(label, dirpath):
        ns = timed("for i in $(seq -w 0 %d); do dd if=/dev/zero of=%s/out-$i.bin "
                   "bs=1M count=%d conv=fsync & done; wait" %
                   (nstream - 1, dirpath, smb))
        rate = mbps(nstream * smb * 1048576, ns)
        client.log("conc write %-8s %d streams x %d MiB: %.2f s, %.0f MB/s aggregate"
                   % (label, nstream, smb, ns / 1e9, rate))
        return rate

    ds_reads0, ds_writes0 = ds_counter("read"), ds_counter("write")
    ds_err0, inflight0 = ds_counter("errors"), ds_counter("inflight_max")

    streams_read("DS direct", "/mnt", "iflag=direct")
    streams_read("MDS direct", "/mnt3", "iflag=direct")
    streams_read("DS buffered", "/mnt", "")
    streams_read("MDS buffered", "/mnt3", "")
    streams_write("DS", "/mnt")
    streams_write("MDS", "/mnt3")

    # Writers sharing one file, disjoint ranges: the contention is the file's own
    # state and the layout's, not the transport. Sixty-four MiB each, because a
    # writer that ends in fsync otherwise measures the fsync - at 16 MiB the
    # round trip was two thirds of the time.
    client.succeed("head -c %d /dev/zero | tr '\\000' 'T' > /mnt/shared.bin" %
                   (256 * 1048576))
    client.succeed("sync")
    for nshare in (1, 3):
        client.succeed("echo 3 > /proc/sys/vm/drop_caches")
        ns = timed("for i in $(seq 0 %d); do dd if=/dev/zero of=/mnt/shared.bin "
                   "bs=1M count=64 seek=$((i*64)) conv=notrunc,fsync & done; wait" %
                   (nshare - 1))
        client.log("conc same-file writers=%d: %.2f s, %.0f MB/s aggregate" %
                   (nshare, ns / 1e9, mbps(nshare * 64 * 1048576, ns)))

    # Four readers of one file while a fifth stream writes another range of it.
    # Cold caches first, or this measures the client's page cache - the writers
    # above have just put their pages there. The readers may see either content
    # across the write - per-unit latest-write-wins is what the MDS path gives
    # too - so this is about throughput and about nothing failing, not the bytes.
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    ns = timed("for i in 1 2 3 4; do dd if=/mnt/shared.bin of=/dev/null bs=1M & "
               "done; (dd if=/dev/zero of=/mnt/shared.bin bs=1M count=64 seek=128 conv=notrunc,fsync) & wait")
    client.log("conc 4 readers + 1 writer on one file: %.2f s "
               "(4 x 256 MiB read, 64 MiB written, %.0f MB/s of reading)" %
               (ns / 1e9, mbps(4 * 256 * 1048576, ns)))

    # The wide writes are checked, not just timed. Every rate above would look
    # just as healthy if a concurrent write had stored the wrong bytes, and the
    # shape where that is most likely - several writers, one file - is the one
    # production actually has.
    def zeros_digest(mb):
        return client.succeed("head -c %d /dev/zero | sha256sum" %
                              (mb * 1048576)).split()[0]

    def range_digest(path, skip_mb, count_mb):
        return server.succeed("dd if=%s bs=1M skip=%d count=%d 2>/dev/null | "
                              "sha256sum" % (path, skip_mb, count_mb)).split()[0]

    want = zeros_digest(smb)
    for i in range(nstream):
        assert sha256_on(server, "/srv/export/out-%02d.bin" % i) == want, \
            "concurrent write %d does not hold what was written" % i
    # shared.bin is 256 MiB: the first three 64 MiB ranges were each written by
    # one of the three writers (and then overwritten with the same zeros by the
    # mixed case), and the fourth nobody touched.
    want64 = zeros_digest(64)
    for i in range(3):
        assert range_digest("/srv/export/shared.bin", i * 64, 64) == want64, \
            "the range writer %d claimed does not hold what it wrote" % i
    wantT = client.succeed("head -c %d /dev/zero | tr '\\000' 'T' | sha256sum" %
                           (64 * 1048576)).split()[0]
    assert range_digest("/srv/export/shared.bin", 192, 64) == wantT, \
        "a range no writer touched was changed"

    # The hot points those cases are for. A wedged data path shows up as the
    # reads above timing out rather than as a number; a service that could not
    # keep up shows up as calls failing or the range falling back; and a client
    # that walks one unit at a time shows up as the backend never having more
    # than one or two calls in its hands.
    assert ds_counter("errors") == ds_err0, \
        "the service failed %d calls under the wide workloads" % \
        (ds_counter("errors") - ds_err0)
    assert counter("ds_read_err") == 0 and counter("ds_write_err") == 0, \
        "the client's calls failed: read_err=%d write_err=%d" % \
        (counter("ds_read_err"), counter("ds_write_err"))
    assert ds_counter("read") > ds_reads0 and ds_counter("write") > ds_writes0, \
        "the wide workloads did not go through the data service"
    assert ds_counter("inflight") == 0, \
        "the service leaked %d in-flight calls" % ds_counter("inflight")
    win = ds_counter("inflight_max")
    client.log("conc: service had %d calls in the backend at once (max), "
               "%d reads and %d writes served" %
               (win, ds_counter("read") - ds_reads0,
                ds_counter("write") - ds_writes0))
    assert win >= 4, \
        "the service never had more than %d calls in the backend at once" % win

    # --- a unit the reply can actually carry --------------------------------
    # Every file read through the data path above compresses to a few hundred
    # bytes a unit ('P' and zeros), which hides how big an encoded unit this
    # backend will actually hand over: a stored extent is not usually a
    # hundredth of its unit. 96 KiB of urandom plus 32 KiB of zeros per 128 KiB
    # unit - the largest unit btrfs stores - keeps three quarters of the unit,
    # and the read still has to come back through the service.
    client.succeed("for i in $(seq 1 32); do head -c 98304 /dev/urandom; "
                   "head -c 32768 /dev/zero; done > /tmp/marginal.bin")
    mdigest = client.succeed("sha256sum /tmp/marginal.bin").split()[0]
    wr0 = ds_counter("write")
    client.succeed("cp /tmp/marginal.bin /mnt/marginal.bin")
    client.succeed("sync")
    client.log("marginal: wrote through the service %d -> %d calls" %
               (wr0, ds_counter("write")))
    assert ds_counter("write") > wr0, \
        "the marginal file's write did not go through the data service"
    assert sha256_on(server, "/srv/export/marginal.bin") == mdigest, \
        "the write through the layout did not store what was written"
    drok = counter("ds_read_ok")
    derr = counter("ds_read_err")
    out = client.succeed("echo 3 > /proc/sys/vm/drop_caches; "
                         "sha256sum /mnt/marginal.bin").strip()
    client.log("marginal: read digest=%s, ds_read_ok %d -> %d, ds_read_err "
               "%d -> %d, last payload %d bytes" %
               (out.split()[0][:16], drok, counter("ds_read_ok"), derr,
                counter("ds_read_err"), counter("ds_last_payload_len")))
    assert out.split()[0] == mdigest, \
        "the marginal file did not read back as it was written"
    assert counter("ds_read_err") == derr, \
        "the service could not send a unit that compresses only a little"
    assert counter("ds_read_ok") > drok, \
        "the marginal file's read did not come from the data service"
    assert counter("ds_last_payload_len") > 32768, \
        "no unit's payload was most of a btrfs unit"

    # --- durability: losing the server does not take committed data back ---
    # Both files are committed by now: unstable.bin through an MDS commit of
    # the data service's unstable writes, file-sync.bin through the data
    # service's own fsync. Cut the power - a crash, not a shutdown, so nothing
    # in the server's page cache is written out on the way down - and both
    # must come back, from their encoded extents on disk.
    cdigests = dict(
        (name, server.succeed("sha256sum /srv/export/%s" % name).split()[0])
        for name in ("unstable.bin", "file-sync.bin"))
    # fdatasync(2) both files: unstable.bin needs the MDS commit, and
    # file-sync.bin is already durable, but the barrier is what a writer would
    # use for either.
    client.succeed("sync -d /mnt/unstable.bin")
    client.succeed("sync -d /mnt/file-sync.bin")
    server.crash()
    server.start()
    # The exported filesystem is mounted explicitly here, so it does not come
    # back on its own, and nfsd restarts after it because the export's path has
    # to exist first. The emulated device is a systemd unit, so it does not
    # exist the instant the machine answers after a restart.
    server.wait_until_succeeds("test -e /dev/mapper/pnfs-data", timeout=120)
    server.succeed("mount /dev/mapper/pnfs-data /srv")
    server.succeed("systemctl restart nfs-server.service")
    server.wait_for_unit("nfs-server.service")

    client.succeed("umount -f /mnt || umount -l /mnt || true")
    client.wait_until_succeeds(
        "mount -t nfs4 -o vers=4.1,timeo=20,retrans=2,write=lazy server:/ /mnt", timeout=300)
    client.succeed("mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug")
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")

    for name, digest in cdigests.items():
        drok_before = counter("ds_read_ok")
        rc, out = client.execute(
            "echo '%s  /mnt/%s' | sha256sum -c - 2>&1" % (digest, name))
        client.log("after the crash: read %s rc=%d, ds_read_ok %d -> %d, out=%s" %
                   (name, rc, drok_before, counter("ds_read_ok"), out.strip()))
        assert rc == 0, \
            "a committed write did not survive the server crash: %s" % out
        assert counter("ds_read_ok") > drok_before, \
            "the read after the crash did not come from the data service"

    # The verifier is the serving netns's own, so a server restart changes it -
    # which is exactly how a client learns that whatever the service never
    # committed is gone.
    client.succeed("sysctl -qw vm.dirty_expire_centisecs=1 vm.dirty_writeback_centisecs=1")
    client.succeed("dd if=/dev/zero of=/mnt/after-crash.bin bs=1M count=2 2>/dev/null")
    server.wait_until_succeeds(
        "test $(stat -c %s /srv/export/after-crash.bin) -eq 2097152", timeout=180)
    verf_after_crash = write_verf()
    client.log("write verifier across the crash: %s -> %s" %
               (verf_before_crash, verf_after_crash))
    assert verf_after_crash != verf_before_crash, \
        "the write verifier survived a server restart: a client could not tell"

    # --- failure modes: the data service failing under a request ------------
    # The design promises that a failure in the data path is never an error the
    # user sees - the range goes back to the MDS - and that promise is only worth
    # something once it has been exercised. There are two ways the path can fail:
    # the service cannot be reached, and the backend cannot store what it was
    # handed. The client-side machinery is the same as the bcachefs suite's; what
    # is different here is only what the backend does with the request.
    # (1) unreachable. The packets are dropped at the server, so the layout, the
    # file handle and the mount all stay up. The rule is in the inet family so
    # it covers whichever family the layout names, and the block is *proved*
    # with the userspace data-service client first: a rule that does not bite
    # would leave this whole case asserting nothing.
    sdigest = sha256_on(server, "/srv/export/perf.bin")
    ds0 = ds_counter("read")
    server.succeed("nft add table inet dsblock")
    server.succeed("nft add chain inet dsblock input "
                   "{ type filter hook input priority 0\\; }")
    server.succeed("nft add rule inet dsblock input tcp dport 2050 drop")
    rc, out = client.execute("timeout 60 dsprobe server 2050 null")
    client.log("datapath down: dsprobe with the port blocked rc=%d %s" %
               (rc, out.strip()[:80]))
    assert rc != 0, "the data service is still reachable with its port blocked"
    rc, out = client.execute("timeout 300 sha256sum /mnt/perf.bin")
    client.log("datapath down: read through the layout rc=%d, service calls "
               "%d -> %d, out=%s" %
               (rc, ds0, ds_counter("read"), out.strip()[:100]))
    assert rc == 0 and out.split()[0] == sdigest, \
        "an unreachable data service turned into an error for the reader"
    assert ds_counter("read") == ds0, \
        "the service answered a call while its port was blocked"
    # The read above is the whole point of the down window and it is what makes
    # this case cheap: one request may pay a timeout, the rest of the file must
    # not. dsprobe proved the block bites, so the calls that never happened are
    # the service being unavailable, and the skips are the requests that did not
    # wait to find that out again.
    assert counter("ds_down") > 0, \
        "the client never noticed the data service was not answering"
    assert counter("ds_down_skips") > 0, \
        "the client kept paying a timeout per request instead of falling back"

    server.succeed("nft delete table inet dsblock")
    # Coming back is on a timer, so poll for it instead of assuming the window
    # has expired: what is being tested is that the client returns to the
    # service on its own, not how long it stays away.
    ds1 = ds0
    for attempt in range(12):
        client.execute("echo 3 > /proc/sys/vm/drop_caches")
        client.execute("sha256sum /mnt/perf.bin >/dev/null")
        ds1 = ds_counter("read")
        if ds1 > ds0:
            break
        client.log("datapath back: still on the MDS (attempt %d)" % (attempt + 1))
        client.execute("sleep 10")
    client.log("datapath back: service calls %d -> %d, ds_down=%d, "
               "ds_down_skips=%d" %
               (ds0, ds1, counter("ds_down"), counter("ds_down_skips")))
    assert ds1 > ds0, \
        "the client never went back to the data service once it was reachable"
    client.succeed("echo '%s  /mnt/perf.bin' | sha256sum -c -" % sdigest)

    # (2) out of space. The exported filesystem is filled through the MDS (it
    # takes incompressible data to occupy anything), then a compressible write
    # goes through the data path: the service's own store fails with ENOSPC, the
    # range goes back to the MDS, and that fails too. The writer has to see
    # ENOSPC - not a hang, and not a quiet success.
    client.execute("rm -f /mnt3/fill.bin")
    rc, out = client.execute(
        "timeout 900 dd if=/dev/urandom of=/mnt3/fill.bin bs=1M 2>&1 | tail -1")
    client.log("filling the export: rc=%d, %s" % (rc, out.strip()[:100]))
    before = counter("ds_write_err")
    rc, out = client.execute(
        "timeout 300 dd if=/dev/zero of=/mnt/nospace.bin bs=1M count=8 "
        "conv=fsync 2>&1")
    client.log("out of space: write through the data path rc=%d (service write "
               "errors %d -> %d): %s" %
               (rc, before, counter("ds_write_err"), out.strip()[:120]))
    assert rc != 0, "a write to a full filesystem succeeded"
    assert "no space" in out.lower(), \
        "the write failed without saying the filesystem was full: %s" % out
    assert counter("ds_write_err") > before, \
        "the service never saw the write that ran out of space"

    # Free it again and check nothing was left broken: the file the reads above
    # hashed is untouched, and the mount still writes what it is given.
    client.succeed("rm -f /mnt3/fill.bin /mnt/nospace.bin")
    client.succeed("sync")
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    # Deleting the filler does not put the space back at once - btrfs frees a
    # removed file's extents asynchronously - so wait for it rather than writing
    # into a filesystem that is still full and calling that a bug.
    client.wait_until_succeeds(
        "head -c 1048576 /dev/zero | tr '\\000' 'Z' > /mnt/after-enospc.bin",
        timeout=300)
    assert sha256_on(server, "/srv/export/after-enospc.bin") == \
        sha256_on(client, "/mnt/after-enospc.bin"), \
        "a write after the filesystem was freed did not store what was written"
    assert sha256_on(server, "/srv/export/perf.bin") == sdigest, \
        "filling the filesystem changed a file that was already there"
    client.log("after ENOSPC: the mount writes again and the old file is intact")
  '';
}
