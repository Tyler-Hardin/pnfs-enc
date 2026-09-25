# NixOS test for the pNFS encoded-extent layout type, bcachefs backend.
#
# Same two-node shape as btrfs.nix (which exercises the btrfs
# backend), but the exported filesystem here is bcachefs, served by the
# out-of-tree module built from this checkout. btrfs is loaded too, as a second
# filesystem under the same layout type: the codecs a filesystem publishes are
# its own, so each export's layout names that filesystem's codecs and the suite
# exercises both at once.
#
# Run it with run-nixos-test.sh:
#   TEST=bcachefs.nix dev/run-nixos-test.sh
#   PROFILE=gce-network-storage TEST=bcachefs.nix dev/run-nixos-test.sh
#
# PROFILE picks the link and the disk from nix/tests/profiles.nix; the default,
# `lan`, is the test bed as it is. The difference is not cosmetic - see
# doc/development.md for what the deployed bed shows that this one cannot.

{ pkgs, lib, src ? ../../bcachefs-tools, profile ? "lan", pgUnitsSweep ? false,
  serverThreads ? 12, wedgeRepro ? false, walkProbe ? false }:

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

  patchedKernel = pkgs.linuxPackages.kernel.override (ccache.override // {
    kernelPatches = [
      {
        name = "pnfs-bcachefs-layout";
        patch = ../patches/pnfs-layout-6.18.patch;
      }
    ];

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

      # Client: NFSv4 with the bcachefs layout driver.
      NFS_FS = lib.mkForce yes;
      NFS_V4 = lib.mkForce yes;
      PNFS_BCACHEFS_LAYOUT = lib.mkForce yes;

      # btrfs is a module rather than built in, so its codec is a provider the
      # client loads on demand like any other: both backends are loaded at once
      # here, one export of each, which is what a per-filesystem codec table is
      # for (the option cannot be disabled outright - BTRFS_FS_POSIX_ACL then
      # becomes an "unused option" to kconfig).
      BTRFS_FS = lib.mkForce (lib.kernel.module);
    };
  });

  linuxPackages = pkgs.linuxPackagesFor patchedKernel;

  # The bcachefs module from this checkout, against the patched kernel, with
  # Rust on (the module the test would ship).
  bcachefsModule = import ../bcachefs-module.nix {
    inherit pkgs lib;
    kernel = patchedKernel;
    src = src;
    rust = true;
  };

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

  common = { pkgs, ... }: {
    imports = [ ./emulation.nix ./corpus.nix ./client.nix ];

    # The client this profile runs. `lan` names none, so it keeps the kernel's.
    virtualisation.testClient = bed.client or { };

    # The benchmark corpus: real float32 volume data, anonymised, attached
    # read-only as raw disks rather than copied - see nix/tests/corpus.nix for
    # why, and nix/tests/data/README.md for what it is.
    virtualisation.testCorpus.dir = ./data;

    boot.kernelPackages = linuxPackages;
    # The bcachefs module lives outside the kernel tree. The server loads it at
    # boot because it mounts the export; the client deliberately does *not* -
    # it needs the module only as a codec provider, and loading it on demand
    # when a layout names "bcachefs-zstd" is itself being tested.
    boot.extraModulePackages = [ bcachefsModule ];
    environment.systemPackages = [ pkgs.nfs-utils pkgs.bcachefs-tools dsprobe pkgs.nftables ]
      ++ lib.optionals walkProbe [ pkgs.fio ];
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

  # Could a deeper read walk pay? The walk inside a request is one unit deep, so
  # a request holding N units pays N round trips one after another - and that
  # cost is measurable without writing any of the concurrency machinery. Read the
  # same file with requests sized to hold one unit (256 KiB, the default
  # export's unit_max), four (1 MiB, what the perf section measures) and
  # thirty-two (8 MiB), and compare: the one-unit rate is the *upper bound* a
  # perfectly pipelined walk could reach for a request of that size, and since
  # those requests also pay the per-request overhead four times over, it is a
  # floor on that bound.
  #
  # What the earlier attempt measured, for the record (commit 3689ac91b, on the
  # lan bed): direct 424 -> 682-762 MB/s with a two-deep walk, buffered 717 ->
  # 295, and a quarter of the unit bytes fetched twice. The waste was the
  # speculation: the client cannot know where the next stored unit starts until
  # the descriptor for the current one arrives, so a prefetch either guesses and
  # re-fetches, or it waits, and waiting is what the one-deep walk already does.
  # This arm is the bound on the other half of that trade.
  walkProbeScript = ''
    # --- could a deeper walk pay? -------------------------------------------
    def walk_point(label, cmd, reps=3):
        best = (0.0, 0, 0, "")
        for _ in range(reps):
            r0, p0 = ds_counter("read"), counter("read_pagelist")
            out = client.succeed(
                "echo 3 > /proc/sys/vm/drop_caches; %s 2>&1" % cmd).strip()
            rate = rate_of(out.splitlines()[-1])
            rpcs = ds_counter("read") - r0
            pgios = counter("read_pagelist") - p0
            if rate > best[0]:
                best = (rate, rpcs, pgios,
                        out.splitlines()[-1].split(", ")[-1])
        rate, rpcs, pgios, tail = best
        print("walk probe %-24s %s [%d RPCs, %d pgios, %.1f units/request]" %
              (label, tail, rpcs, pgios, float(rpcs) / max(pgios, 1)))
        return rate

    unit = walk_point("direct 256K (1 unit)",
                      "dd if=/mnt/perf.bin of=/dev/null bs=256K iflag=direct")
    four = walk_point("direct 1M (4 units)",
                      "dd if=/mnt/perf.bin of=/dev/null bs=1M iflag=direct")
    walk_point("direct 8M (32 units)",
               "dd if=/mnt/perf.bin of=/dev/null bs=8M iflag=direct")
    buf = walk_point("buffered 1M",
                     "dd if=/mnt/perf.bin of=/dev/null bs=1M", reps=1)
    print("walk probe: one unit per request reaches %.0f MB/s against %.0f MB/s "
          "for the four-unit request the perf section measures, so a perfectly "
          "pipelined walk is worth at most %.1fx there - and it has to buy that "
          "without fetching a unit twice." % (unit, four, unit / max(four, 1)))

    # mmap, sequential, one thread: the shape a reader actually arrives in when
    # it is not calling read(2). Faults go through the same pgio path as a
    # buffered read, with readahead doing the concurrency, so it should land at
    # the buffered number rather than the direct one - and it is the readahead
    # window, not the walk, that decides. fio's mmap engine is told not to
    # invalidate the file, or it rewrites it and we measure a write.
    def fio_rate(out):
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("READ: bw="):
                # "bw=138MiB/s (145MB/s), ...": the parenthesised MB/s follows
                # without a comma, so take the first whitespace-separated token.
                val = line.split("bw=")[1].split()[0]
                for scope, scale in (("GiB", 1024.0), ("MiB", 1.0),
                                     ("KiB", 1 / 1024.0)):
                    if val.endswith(scope + "/s"):
                        return float(val[:-len(scope + "/s")]) * scale
        raise Exception("no READ rate in fio's output:\n" + out)

    def mmap_point(label, extra="", jobs=1, size="64M"):
        r0, p0 = ds_counter("read"), counter("read_pagelist")
        out = client.succeed(
            "echo 3 > /proc/sys/vm/drop_caches; fio --name=mmap "
            "--ioengine=mmap --rw=read --bs=64K --size=%s --numjobs=%d "
            "--filename=/mnt/perf.bin --readonly --invalidate=0 "
            "--group_reporting %s" % (size, jobs, extra))
        rate = fio_rate(out)
        rpcs = ds_counter("read") - r0
        pgios = counter("read_pagelist") - p0
        print("walk probe %-24s %.0f MB/s [%d RPCs, %d pgios]" %
              (label, rate, rpcs, pgios))
        return rate

    print("walk probe: readahead window: %s" %
          client.succeed("cat /sys/class/bdi/*/read_ahead_kb").replace("\n", " "))
    mmap = mmap_point("mmap 1 job")
    mmap_point("mmap 4 jobs", jobs=4)
    print("walk probe: mmap sequential reaches %.0f MB/s against %.0f MB/s for "
          "read(2) buffered and %.0f MB/s for one direct request: the fault path "
          "is the buffered path plus page faults, and readahead is what puts its "
          "requests in flight." % (mmap, buf, four))
  '';

  # The wedge, on purpose: the regression case for gotchas 28 and 29. Repeating a
  # *buffered* read through the data path stopped the data service answering
  # twice - once in round 17 and once during the pg_units work, each time costing
  # a run - and neither occurrence captured the state that says where it stopped.
  # It is understood now, and it was two bugs stacked. The client's data-service
  # transport had gone away, a soft RPC timeout does not reconnect, and the client
  # was kept for the rest of the layout's life, so every unit paid the timeout
  # again (gotcha 28, fixed by bc_ds_clnt_drop()); and underneath that, the
  # backend's encoded read leaked a bounce page per unit until the *server* ran
  # out of memory and panicked (gotcha 29, fixed in fs/encoded_extent.c). The
  # first fix is what let the arm finish its reads and exposed the second, and
  # this arm is what found both, so it stays, bounded and gated - a full 737 MiB
  # read per pass, twelve passes, past the sixth or seventh that used to stop:
  #
  #   nix build --impure --expr '... wedgeRepro = true;'
  #
  # It runs before the durability section because that section crashes the
  # server, and the driver does not appear to re-attach the server's console
  # afterwards - which is exactly why the first two occurrences were opaque.
  # The read runs in the background and the dump happens while it is still in
  # flight, because the state that says where it stopped - the RPC task that is
  # not completing, and the stack of the process waiting for it - is gone by the
  # time a timeout has killed the reader. Every command in the dump is
  # best-effort, too: the first version of this used succeed(), so the one
  # command whose path was wrong (the sunrpc debugfs directory is rpc_xprt, not
  # xprt) raised and the decisive lines were never printed. And the background
  # job's own descriptors have to be redirected away from the driver's pipe, or
  # Machine.execute() reads until the job exits and the poll below never runs.
  wedgeArm = ''
    # --- the wedge, on purpose ----------------------------------------------

    def wrun(m, cmd):
        rc, out = m.execute(cmd)
        return out.strip() or "(rc=%d, no output)" % rc

    cstat = ("for f in read_pagelist ds_read_ok ds_read_err ds_read_wasted "
             "ds_down ds_down_skips ds_last_read_err; do printf '%s=%s ' $f "
             "$(cat /sys/kernel/debug/pnfs_bcachefs/$f); done")
    sstat = ("for f in read write inflight inflight_max errors not_encoded "
             "codec_unknown; do printf '%s=%s ' $f "
             "$(cat /sys/kernel/debug/encoded_ds/$f); done")
    # The server's memory, and who is holding it. The wedge's last form was the
    # server running out of memory and panicking (panic_on_oom), which is
    # invisible from the counters above: Mem-Info showed only ~300 MB accounted
    # for out of 8 GiB, which is what a vmalloc leak looks like, so the caller
    # histogram is what names it.
    memstat = ("awk '/^(MemFree|MemAvailable|VmallocUsed|SReclaimable|Slab):/ "
               "{printf \"%s=%s \", $1, $2}' /proc/meminfo")
    vmalloc = ("grep -o ' [A-Za-z_][A-Za-z0-9_]*+0x[0-9a-f]*' /proc/vmallocinfo "
               "| sort | uniq -c | sort -rn | head -12 | tr '\\n' '|'")

    def wdump(tag):
        print("wedge[%s]: client counters: %s" % (tag, wrun(client, cstat)))
        print("wedge[%s]: server counters: %s" % (tag, wrun(server, sstat)))
        print("wedge[%s]: server memory: %s" % (tag, wrun(server, memstat)))
        print("wedge[%s]: server vmalloc callers: %s" % (tag, wrun(server, vmalloc)))
        print("wedge[%s]: client sockets: %s" % (tag, wrun(
            client, "ss -tan | grep -E '2049|2050' | tr '\\n' '|' || echo none")))
        # rpc_clnt/<id>/tasks prints every task with the queue it is waiting on,
        # which is the one thing that says whether a request is waiting for a
        # transport slot, for a connect, or for a reply that is not coming.
        print("wedge[%s]: client rpc tasks: %s" % (tag, wrun(
            client, "cat /sys/kernel/debug/sunrpc/rpc_clnt/*/tasks 2>/dev/null "
            "| tr '\\n' '|' | cut -c1-1800")))
        print("wedge[%s]: client rpc transports: %s" % (tag, wrun(
            client, "for d in /sys/kernel/debug/sunrpc/rpc_xprt/*; do "
            "printf '[%s] ' $(basename $d); tr '\\n' ' ' < $d/info; echo; "
            "done | cut -c1-1800")))
        print("wedge[%s]: client dd stack: %s" % (tag, wrun(
            client, "for p in $(pgrep -x dd); do printf 'dd %s: ' $p; "
            "cat /proc/$p/stack | tr '\\n' ' '; echo; done")))
        print("wedge[%s]: client dmesg: %s" % (tag, wrun(
            client, "dmesg | tail -6 | tr '\\n' '|'")))
        print("wedge[%s]: server dmesg: %s" % (tag, wrun(
            server, "dmesg | tail -6 | tr '\\n' '|'")))
        # Three paths to the same bytes, and which of them is stuck says which
        # side the stall is on: the server reading its own file (no nfsd, no
        # service), the client reading a *different* file cold (nfsd and the
        # service, a different inode and layout), and the client reading this
        # one cold. A cached read proves nothing, which is how the first
        # version of this line managed to report 319 MB/s through a stalled
        # nfsd.
        print("wedge[%s]: a read on the server itself: %s" % (tag, wrun(
            server, "timeout 20 dd if=/srv/export/real.bin of=/dev/null "
            "bs=1M count=32 2>&1 | tail -1")))
        print("wedge[%s]: a cold read of another file: %s" % (tag, wrun(
            client, "echo 3 > /proc/sys/vm/drop_caches; timeout 20 dd "
            "if=/mnt/perf.bin of=/dev/null bs=1M count=4 2>&1 | tail -1")))
        print("wedge[%s]: a cold read of the same file: %s" % (tag, wrun(
            client, "echo 3 > /proc/sys/vm/drop_caches; timeout 20 dd "
            "if=/mnt/real.bin of=/dev/null bs=1M count=8 2>&1 | tail -1")))
        # Where the server is, if it is the server: a task blocked in the
        # filesystem, in nfsd's state handling or in the service's own open all
        # look the same from the client, and the stacks tell them apart.
        print("wedge[%s]: server blocked tasks: %s" % (tag, wrun(
            server, "for p in $(ps -eLo pid,stat | awk '$2 ~ /^[DR]/ "
            "{print $1}'); do printf '%s(%s): ' $p $(cat /proc/$p/comm); "
            "cat /proc/$p/stack 2>/dev/null | tr '\\n' ' '; echo; done "
            "| cut -c1-2400")))
        print("wedge[%s]: server nfsd and service threads: %s" % (tag, wrun(
            server, "ps -eLo stat,wchan:28,comm | grep -E 'nfsd|encoded_ds' "
            "| tr '\\n' '|' | cut -c1-1600")))

    print("wedge: before: server memory: %s" % wrun(server, memstat))
    print("wedge: before: server vmalloc callers: %s" % wrun(server, vmalloc))
    derr0, ddown0 = counter("ds_read_err"), counter("ds_down")
    for i in range(12):
        client.succeed("echo 3 > /proc/sys/vm/drop_caches")
        client.succeed("rm -f /tmp/dd.out /tmp/dd.rc")
        # Detached, and with every descriptor pointed away from the driver's
        # pipe: a background job that keeps the shell's stdout open keeps
        # Machine.execute() reading until the job exits, which is the opposite
        # of what this is for. The inner timeout is longer than the poll below,
        # so the dump happens while the read is still in flight.
        client.execute("setsid sh -c 'timeout 120 dd if=/mnt/real.bin "
                       "of=/dev/null bs=8M > /tmp/dd.out 2>&1; "
                       "echo $? > /tmp/dd.rc' </dev/null >/dev/null 2>&1 &")
        rc = None
        for _ in range(40):
            if client.execute("test -e /tmp/dd.rc")[0] == 0:
                rc = int(client.succeed("cat /tmp/dd.rc").strip())
                break
            client.execute("sleep 1")
        print("wedge: read %d: rc=%s, %s | server %s" %
              (i, rc, wrun(client, cstat), wrun(server, memstat)))
        if rc != 0:
            client.log("wedge: read %d did not finish in 40s; the service "
                       "answers on the server itself: %s" %
                       (i, server.execute("timeout 20 dsprobe 127.0.0.1 2050 "
                                          "null")[0] == 0))
            print("wedge: client mount still does attributes: %s" %
                  client.execute("timeout 20 stat -c %s /mnt/real.bin")[0])
            print("wedge: client dsprobe over the network: rc=%d" %
                  client.execute("timeout 20 dsprobe server 2050 null")[0])
            wdump("hung")
            client.execute("sleep 5")
            wdump("hung+5s")
            client.execute("pkill -x dd")
            assert False, ("the client's read stopped after %d reads, with the "
                           "service itself healthy" % i)
    print("wedge: 12 buffered reads and the service never stopped answering")
    # Finishing is not enough to say the data path is healthy: the leak that was
    # underneath this arm did not stop the reads, it made the server go into
    # reclaim and pay a timeout per unit - read 6 of one run finished with
    # ds_read_err 113 and ds_down 1. A timeout here means the service was not
    # answering, and on this bed (the link profile has no packet loss) that is a
    # bug rather than variance, so the counters have to be where they started.
    assert counter("ds_read_err") == derr0, \
        "the data path paid a timeout with the service answering " \
        "(ds_read_err %d -> %d)" % (derr0, counter("ds_read_err"))
    assert counter("ds_down") == ddown0, \
        "the service was marked down while it was answering " \
        "(ds_down %d -> %d)" % (ddown0, counter("ds_down"))
  '';

  # The pg_units sweep: not part of what the suite asserts - every run passes
  # with it off - but the experiment that says whether the request size is
  # enough on this bed or whether the walk inside a request needs work.
  #
  # `bc_pg_bsize()` is max(unit_max * pg_units, rsize) capped at 8 MiB, so on a
  # 1 MiB-unit export (the deployment's shape) pg_units=1 is one unit per
  # request and 8 is eight. Bigger requests cross fewer unit boundaries, so the
  # service re-fetches less; the walk is one unit deep, so they also pay their
  # round trips one after another. Which dominates is the measurement.
  pgUnitsSweepScript = ''
    # --- pg_units -----------------------------------------------------------
    # `bc_pg_bsize()` is max(unit_max * pg_units, rsize) capped at 8 MiB, so on
    # the default export (256 KiB units, 1 MiB rsize) the request is 1 MiB at
    # pg_units 1-4, 2 MiB at 8 and 4 MiB at 16. Two things are worth separating:
    #
    #   - a request cannot be bigger than the read() that asked for it. `dd
    #     bs=1M` therefore reads 1 MiB per request whatever the knob says, and
    #     that is the shape a deployment's single-stream reader has.
    #   - bigger requests cross fewer unit boundaries, so the service re-fetches
    #     less; but the walk inside a request is one unit deep, so a request
    #     with four units in it pays four round trips one after another rather
    #     than four at once.
    #
    # The sweep is printed, not asserted, except for the one thing that has to
    # be true for the table to mean anything: with a reader big enough to let
    # the pgio grow, the request size has to change.

    def sweep_rate(cmd):
        out = client.succeed("echo 3 > /proc/sys/vm/drop_caches; %s 2>&1" % cmd)
        return rate_of(out.splitlines()[-1])

    def sweep_point(path, units, bs, reps=2):
        client.succeed("echo %d > /sys/kernel/debug/pnfs_bcachefs/pg_units" % units)
        pg0, rpc0, ns0 = counter("read_pagelist"), ds_counter("read"), ds_counter("read_ns")
        w0, b0 = counter("ds_read_wasted"), counter("ds_read_bytes")
        direct = max(sweep_rate("dd if=%s of=/dev/null bs=%s iflag=direct" % (path, bs))
                     for _ in range(reps))
        # One buffered read, not `reps` of them: repeating a buffered read
        # through the data path is the wedge the perf section already documents,
        # and twenty-five of them in a row here hung the bcachefs server and cost
        # a run twenty minutes. The counters are normalised over what happened.
        buffered = sweep_rate("dd if=%s of=/dev/null bs=%s" % (path, bs))
        reads = float(reps + 1)
        return {
            "units": units,
            "bs": bs,
            "unit_max": counter("unit_max"),
            "unit_len": counter("ds_last_unit_len"),
            "direct": direct,
            "buffered": buffered,
            "pgios": (counter("read_pagelist") - pg0) / reads,
            "rpcs": (ds_counter("read") - rpc0) / reads,
            "waste": 100.0 * (counter("ds_read_wasted") - w0)
                     / float(max(counter("ds_read_bytes") - b0, 1)),
            "us_rpc": (ds_counter("read_ns") - ns0)
                      / float(max(ds_counter("read") - rpc0, 1)) / 1000.0,
        }

    def sweep(label, path, mds_path):
        print("pg_units sweep: %s" % label)
        print("pg_units sweep: %5s %7s %9s %9s %7s %7s %7s %7s %9s %9s" % (
            "units", "dd bs", "DSdirect", "DSbuf", "pgios", "RPCs", "waste%",
            "us/RPC", "unit_max", "unit_len"))
        rows = []
        for bs in ("1M", "8M"):
            for u in (1, 2, 4, 8, 16):
                r = sweep_point(path, u, bs)
                rows.append(r)
                print("pg_units sweep: %5d %7s %9.0f %9.0f %7.1f %7.1f %7.1f %7.0f %9d %9d" % (
                    r["units"], r["bs"], r["direct"], r["buffered"], r["pgios"],
                    r["rpcs"], r["waste"], r["us_rpc"], r["unit_max"], r["unit_len"]))
        for bs in ("1M", "8M"):
            print("pg_units sweep: MDS control bs=%s: direct %.0f, buffered %.0f" % (
                bs,
                sweep_rate("dd if=%s of=/dev/null bs=%s iflag=direct" % (mds_path, bs)),
                sweep_rate("dd if=%s of=/dev/null bs=%s" % (mds_path, bs))))
        big = [r for r in rows if r["bs"] == "8M"]
        assert big[-1]["pgios"] < big[0]["pgios"], \
            "with bs=8M the knob did not change the request size: %s" % \
            [r["pgios"] for r in big]
        small = [r for r in rows if r["bs"] == "1M"]
        print("pg_units sweep: requests per 64 MiB read at dd bs=1M: %s" %
              [round(r["pgios"], 1) for r in small])
        return rows

    # --- the straddle, on purpose -------------------------------------------
    # The deployment's units average 944 KB against 1 MiB requests, so a request
    # covers the tail of one stored extent and the head of the next: 1.8 service
    # calls per stored unit, ds_read_wasted 0.68, and about 45% of the service's
    # work spent fetching what a neighbouring request already had. This bed's
    # default export cannot show that - its units are 256 KiB and divide a 1 MiB
    # request exactly, so its waste is 0.0 - so this one uses the 1 MiB-unit
    # filesystem and writes the file *on the server*, where bcachefs's own write
    # path decides the extent sizes, the way a deployment's data arrives.
    #
    # The readout is deliberately the deployment's own vocabulary: the average
    # served unit (ds_read_bytes / ds_read_ok), the waste, and service calls per
    # stored unit, which is what 1.8 and 0.68 are measurements of.
    server.succeed("mountpoint -q /srv/export/big || "
                   "mount -t bcachefs /dev/mapper/pnfs-big /srv/export/big")
    # Direct writes of 944 KiB, which is the deployment's average stored unit:
    # bcachefs stores one extent a write, so the extents do not divide a 1 MiB
    # request and every request straddles two of them. (A plain buffered copy
    # gives uniform 1 MiB extents and no straddle at all, which is what the
    # first run of this measured: average unit 1,047,949 bytes, waste 0.0.)
    server.succeed("dd if=/dev/disk/by-id/virtio-corpus-test8 "
                   "of=/srv/export/big/straddle.bin bs=944K count=68 "
                   "oflag=direct status=none")
    server.succeed("sync")
    print("straddle: %s MiB written by the server into the 1 MiB-unit export"
          % server.succeed("du -m /srv/export/big/straddle.bin | cut -f1").strip())

    def straddle_point(pg_units):
        client.succeed("echo %d > /sys/kernel/debug/pnfs_bcachefs/pg_units" % pg_units)
        r0, ns0 = ds_counter("read"), ds_counter("read_ns")
        b0, ok0, w0 = (counter("ds_read_bytes"), counter("ds_read_ok"),
                       counter("ds_read_wasted"))
        p0 = counter("read_pagelist")
        mbs = sweep_rate("dd if=/mnt/big/straddle.bin of=/dev/null bs=1M")
        read = ds_counter("read") - r0
        got = counter("ds_read_bytes") - b0
        unit = got / float(max(counter("ds_read_ok") - ok0, 1))
        return {
            "pg": pg_units,
            "mbs": mbs,
            "unit": unit,
            "waste": 100.0 * (counter("ds_read_wasted") - w0) / float(max(got, 1)),
            "calls": read * unit / float(max(got, 1)),
            "pgios": counter("read_pagelist") - p0,
            "rpcs": read,
            "us": (ds_counter("read_ns") - ns0) / float(max(read, 1)) / 1000.0,
        }

    print("straddle: %7s %9s %11s %9s %11s %7s %7s %8s" % (
        "pg_units", "MB/s", "avg unit", "waste%", "calls/unit", "pgios", "RPCs",
        "us/RPC"))
    straddle = [straddle_point(p) for p in (1, 2, 4, 8)]
    for r in straddle:
        print("straddle: %7d %9.0f %11.0f %9.1f %11.2f %7d %7d %8.0f" % (
            r["pg"], r["mbs"], r["unit"], r["waste"], r["calls"], r["pgios"],
            r["rpcs"], r["us"]))
    # The reproduction is the assertion: this file has to straddle, or the arm
    # is measuring the aligned case again.
    assert straddle[0]["waste"] > 10.0, \
        "the file did not straddle: waste %s" % [round(r["waste"], 1) for r in straddle]
    # Whether the knob moved the pgio is a *report*, not an assertion: a pgio is
    # only as big as the pages ready for it, so with a short file - or a stock
    # client, whose readahead is 128 KB - it reaches nothing at all, and that is
    # a property of the client rather than a failure of the driver.
    print("straddle: requests per read: %s" % [r["pgios"] for r in straddle])
    if straddle[-1]["pgios"] < straddle[0]["pgios"]:
        assert straddle[-1]["waste"] < straddle[0]["waste"], \
            "the waste did not fall with bigger requests: %s" % \
            [round(r["waste"], 1) for r in straddle]
    else:
        print("straddle: the knob did not reach the pgio on this run")

    # Real data, and the client the profile asked for: a 64 MiB slice of the
    # corpus, written through the layout so the service holds this data's
    # encoded units. The full file is 737 MiB, which is right for a headline
    # number and too slow to sweep.
    client.succeed("dd if=/dev/disk/by-id/virtio-corpus-test8 of=/mnt/real64.bin "
                   "bs=1M count=64 status=none")
    client.succeed("sync")
    print("pg_units sweep: client read_ahead_kb %s, tcp_slot_table_entries %s" % (
        client.succeed("cat /sys/class/bdi/0:*/read_ahead_kb | sort -u").strip(),
        client.succeed("cat /proc/sys/sunrpc/tcp_slot_table_entries").strip()))
    sweep("real data (corpus test8), 256 KiB units against a 1 MiB rsize",
          "/mnt/real64.bin", "/mnt3/real64.bin")
  '';


in
pkgs.testers.nixosTest {
  # The bed belongs in the name: two runs of this suite on two profiles are two
  # different machines' numbers.
  name = "pnfs-bcachefs-encoded-extent" + lib.optionalString (profile != "lan") "-${profile}";

  nodes = {
    server = { pkgs, ... }: {
      imports = [ common ];

      # It mounts the export, so its filesystem's module is loaded from boot.
      boot.kernelModules = [ "bcachefs" ];

      # One data-service thread per vCPU by default: the service is where the
      # concurrency of a wide workload has to be absorbed, and the kernel's own
      # default is eight, which would cap a twelve-core server before the
      # filesystem did. `serverThreads` exists because a deployment sets this
      # much higher - 128 threads on 16 vCPUs, where the threads are for
      # concurrency rather than for work - and what that buys is a measurement,
      # not a guess. The parameter belongs to the object the service is linked
      # into, which is nfsd - the test reads it back, because a name the kernel
      # does not know is dropped in silence and the service then runs on its
      # default.
      boot.kernelParams = [ "nfsd.encoded_ds_nthreads=${toString serverThreads}" ];

      # The failure mode this project's work keeps running into is a hang, not a
      # wrong answer, and a hang that only says "timed out" costs a round to
      # diagnose. A backtrace after thirty seconds of an un-interruptible task is
      # the cheapest evidence there is.
      boot.kernel.sysctl."kernel.hung_task_timeout_secs" = lib.mkForce 30;

      systemd.tmpfiles.rules = [ "d /srv/export 0777 root root -" ];

      environment.systemPackages = [ pkgs.btrfs-progs ];

      # The export disks. The emulation module declares the drives (that is
      # where QEMU's bandwidth cap lives) and puts a dm-delay device in front of
      # each, so the test's path is /dev/mapper/<name> in every profile: a
      # zero-delay delay target is a remap and nothing else.
      virtualisation.testEmulation.disks = {
        pnfs-data = { size = 4096; } // disk;
        pnfs-btrfs = { size = 4096; } // disk;
        pnfs-big = { size = 4096; } // disk;
      };

      services.nfs.server.enable = true;
      services.nfs.server.exports = ''
        /srv/export *(rw,fsid=0,insecure,no_subtree_check,crossmnt,pnfs,no_root_squash)
        /srv/export/btrfs *(rw,fsid=1,insecure,no_subtree_check,pnfs,no_root_squash)
        /srv/export/big *(rw,fsid=2,insecure,no_subtree_check,pnfs,no_root_squash)
      '';
    };

    client = { ... }: {
      imports = [ common ];

      # The reader's cores, if the profile names them: a deployment's client is
      # not the same size as the test bed's node, and if the client is what
      # limits a single stream then pretending otherwise hides it.
      virtualisation.cores = bed.clientCores or 12;
    };

    # A second client of the same export: coherence between clients is the one
    # property a single client cannot test. It carries no load, so it does not
    # need the resources the two working nodes get.
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

    # The profile's client, if it names one; 0 means the kernel's own settings.
    RA_KB = ${if bed ? client && bed.client ? readAheadKB then toString bed.client.readAheadKB else "0"}
    SLOTS = ${if bed ? client && bed.client ? tcpSlotTableEntries then toString bed.client.tcpSlotTableEntries else "0"}

    def counter(name):
        return int(client.succeed("cat /sys/kernel/debug/pnfs_bcachefs/%s" % name))

    def ds_counter(name):
        return int(server.succeed("cat /sys/kernel/debug/encoded_ds/%s" % name))

    start_all()
    client.wait_until_succeeds("ping -c1 -w1 server", timeout=120)

    for name, m in (("server", server), ("client", client)):
        rc, out = m.execute("systemd-detect-virt")
        m.log("%s virt: %s (rc=%d)" % (name, out.strip(), rc))

    # The nfsd half is in the kernel; the bcachefs backend is a module, loaded
    # on the server because it mounts the export - and deliberately *not* on the
    # client, where it is only ever a codec's provider and is loaded by name
    # when a layout asks for it.
    server.succeed("grep -qw bc_layout_ops /proc/kallsyms")
    server.succeed("grep -qw bch2_encoded_extent_ops /proc/kallsyms")
    client.fail("grep -qw bch2_encoded_extent_ops /proc/kallsyms")
    client.fail("grep -qw btrfs_encoded_extent_ops /proc/kallsyms")

    # --- server: a compressed bcachefs export ----------------------------
    # compression has OPT_FORMAT, and this bcachefs refuses it as a mount
    # option ("may no longer be specified at mount time"), so set the
    # filesystem default at format time and mount plainly.
    #
    # encoded_extent_max is format-time too (OPT_FS|OPT_FORMAT): it is both the
    # largest unit the layout will advertise and the largest encoded payload the
    # backend will produce, and its default is 256 KiB. Raising it is the
    # per-unit cost lever - the service pays a btree transaction, a checksum and
    # two copies per unit whatever its size - but it is left at the default here
    # so the numbers are about the path, not about a tuning choice.
    server.succeed("mkfs.bcachefs -f -L pnfsdata --replicas=1 --compression=zstd /dev/mapper/pnfs-data")
    server.succeed("mount -t bcachefs /dev/mapper/pnfs-data /srv/export")

    # A second filesystem, on its own disk, mounted inside the exported tree and
    # exported in its own right: the same client is served two filesystems under
    # one layout type. Mounted inside the tree so the client reaches it by
    # crossing the mount (the parent export has crossmnt), and exported so the
    # data service can resolve the handles nfsd hands out for its files - those
    # carry this filesystem's fsid, not the parent's.
    server.succeed("mkfs.btrfs -f -L pnfsbtrfs /dev/mapper/pnfs-btrfs")
    server.succeed("mkdir -p /srv/export/btrfs")
    server.succeed("mount -o compress=zstd:1 /dev/mapper/pnfs-btrfs /srv/export/btrfs")
    server.succeed("head -c 4194304 /dev/zero | tr '\\000' 'Q' > /srv/export/btrfs/btrfs.bin")
    server.log("second filesystem: " +
               server.succeed("findmnt -no FSTYPE,SOURCE /srv/export/btrfs").strip())
    # A third filesystem, with an encoded extent ceiling this time rather than
    # btrfs's fixed 128 KiB: 1 MiB units, which is what makes a stored payload
    # of most of a megabyte possible. Nothing else on this server can produce
    # one - the default ceiling is 256 KiB - so this is the only place the
    # client's receive path is asked for more than a reply buffer could hold.
    server.succeed("mkfs.bcachefs -f -L pnfsbig --replicas=1 --compression=zstd "
                   "--encoded_extent_max=1M /dev/mapper/pnfs-big")
    server.succeed("mkdir -p /srv/export/big")
    server.succeed("mount -t bcachefs /dev/mapper/pnfs-big /srv/export/big")
    server.log("third filesystem: " +
               server.succeed("findmnt -no FSTYPE,SOURCE /srv/export/big").strip())
    server.succeed("chmod 0777 /srv/export/big")
    server.succeed("chmod 0777 /srv/export")
    server.succeed("head -c 4194304 /dev/urandom > /srv/export/random.bin")
    server.succeed("dd if=/dev/zero of=/srv/export/zeros.bin bs=1M count=4 2>/dev/null")
    server.succeed("sync")
    server.log("mount: " + server.succeed("findmnt -no FSTYPE,OPTIONS /srv/export").strip())
    # The effective per-file options are what bch2_inode_opts_get_inode() will
    # resolve on the server side of an encoded write; log them so a compression
    # regression is visible rather than inferred from the counters.
    server.log("zeros.bin effective options: " +
               server.succeed("bcachefs get-file-option --effective /srv/export/zeros.bin 2>&1 | tr '\\n' ' '"))

    server.succeed("systemctl restart nfs-server.service")
    server.wait_for_unit("nfs-server.service")
    server.succeed("exportfs -v")

    # --- client: mount, then read ----------------------------------------
    client.succeed("mkdir -p /mnt")
    mounted = False
    for opts, target in [
        ("vers=4.1,timeo=20,retrans=2,write=lazy", "server:/"),
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
    client2.wait_until_succeeds("ping -c1 -w1 server", timeout=120)
    client2.succeed("mkdir -p /mnt")
    client2.wait_until_succeeds(
        "mount -t nfs4 -o vers=4.1,timeo=20,retrans=2,write=lazy server:/ /mnt",
        timeout=300)
    if SLOTS:
        got = client.succeed("cat /proc/sys/sunrpc/tcp_slot_table_entries").strip()
        assert got == str(SLOTS), \
            "sunrpc.tcp_slot_table_entries is %s, not the profile's %s" % (got, SLOTS)
    if RA_KB:
        # A bdi appears when its superblock is mounted, so the module's timer
        # cannot have covered the mount above: run it now, the way the
        # deployment's 15-minute timer eventually would.
        client.succeed("systemctl start nfs-readahead.service")
        got = client.succeed("cat /sys/class/bdi/0:*/read_ahead_kb | sort -u").split()
        client.log("client: tcp_slot_table_entries %s, read_ahead_kb %s "
                   "(profile asks for %s and %s KB)" %
                   (SLOTS, " ".join(got), SLOTS, RA_KB))
        assert str(RA_KB) in got, \
            "read_ahead_kb is %s, not the profile's %s" % (got, RA_KB)
    client2.succeed("mountpoint -q /mnt")
    client.succeed("test -d /sys/kernel/debug/pnfs_bcachefs")

    for name in ("random.bin", "zeros.bin"):
        digest = server.succeed("sha256sum /srv/export/%s" % name).split()[0]
        rc, out = client.execute(
            "echo '%s  /mnt/%s' | sha256sum -c - 2>&1" % (digest, name))
        client.log("read %s rc=%d out=%s" % (name, rc, out))
        if rc != 0:
            client.log("client counters on failure: lseg_alloc=%d lseg_alloc_err=%d "
                       "read_pagelist=%d unit_max=%d unit_align=%d layout_codecs=%d "
                       "codec_missing=%d read_ok=%d read_err=%d not_encoded=%d last_err=%d" %
                       (counter("lseg_alloc"), counter("lseg_alloc_err"),
                        counter("read_pagelist"), counter("unit_max"),
                        counter("unit_align"), counter("layout_codecs"),
                        counter("codec_missing"), counter("ds_read_ok"),
                        counter("ds_read_err"), counter("ds_read_not_encoded"),
                        counter("ds_last_read_err")))
            client.log("client dmesg:\n" + client.succeed("dmesg | tail -50 2>&1 || true"))
            server.log("server dmesg:\n" + server.succeed("dmesg | tail -50 2>&1 || true"))
        assert rc == 0, "read of %s failed: %s" % (name, out)

    # The client's codec provider is a module it did not have: the first layout
    # named a codec it could not resolve, so it asked for the module that
    # advertises that alias, modprobe loaded bcachefs, and the second look
    # resolved the name. That path has now run once, and must not run again.
    client.succeed("grep -qw bch2_encoded_extent_ops /proc/kallsyms")
    client.succeed("lsmod | grep -q '^bcachefs '")
    codec_requests = counter("codec_requests")
    client.log("client asked for a codec provider %d time(s); module-requested "
               "codec load worked" % codec_requests)
    assert codec_requests >= 1, \
        "the client never asked for the codec's provider module"

    # --- the data service -------------------------------------------------
    server.succeed("mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug")
    server.succeed("test -d /sys/kernel/debug/encoded_ds")
    # ... and running the threads it was asked for. A parameter the kernel does
    # not know is ignored without a word, and the service then runs on its
    # default of eight, which is where a wide workload would quietly cap.
    assert int(server.succeed(
        "cat /sys/module/nfsd/parameters/encoded_ds_nthreads")) == ${toString serverThreads}, \
        "the data service is not running the threads the test asked for"
    server.succeed("dsprobe 127.0.0.1 2050 null")
    client.succeed("dsprobe server 2050 null")

    # --- the layout, and the client's view of it -------------------------
    lseg = counter("lseg_alloc")
    assert lseg >= 1, "client never negotiated a layout (lseg_alloc=%d)" % lseg
    assert counter("lseg_alloc_err") == 0, "client failed to decode the layout body"
    rp = counter("read_pagelist")
    assert rp >= 1, "client never reached the pnfs read path (read_pagelist=%d)" % rp

    umax = counter("unit_max")
    ualign = counter("unit_align")
    server.log("layout caps: unit_max=%d unit_align=%d" % (umax, ualign))
    assert umax >= 4096 and (umax & (umax - 1)) == 0, \
        "layout carried unit_max=%d, expected a power of two >= 4096" % umax
    assert ualign >= 512, "layout carried unit_align=%d" % ualign

    lc = counter("layout_codecs")
    assert lc >= 1, "the layout named no codecs (layout_codecs=%d)" % lc
    assert counter("codec_missing") == 0, \
        "the client could not resolve %d of the %d codecs the layout named" % \
        (counter("codec_missing"), lc)
    wc = counter("write_codec")
    assert 0 <= wc < lc, \
        "writes would use codec position %d of %d: no codec to encode with" % (wc, lc)

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
        "the incompressible file was not refused by the service (not_encoded=%d)" % drne
    assert sread >= drok, "server served %d reads for %d client completions" % (sread, drok)
    assert srne >= 1, "the server never refused a range as unencoded"
    assert ds_counter("codec_unknown") == 0, \
        "the server could not map a codec for an extent it served"
    assert io_read < 6 * 1024 * 1024, \
        "nfsd read %d bytes: zeros.bin did not come from the data service" % io_read

    # --- client: write through the layout ---------------------------------
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

    # More layouts have been fetched since (each file's open fetches one), and
    # the provider is loaded now, so the name resolves on the first look and
    # modprobe is not asked again.
    assert counter("codec_requests") == codec_requests, \
        "the client asked for the codec's provider again after it had resolved " \
        "(%d -> %d)" % (codec_requests, counter("codec_requests"))

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

    synced = counter("sync")
    server.log("layout sync calls after the write: %d" % synced)
    assert synced >= 1, "the client never reached the layout commit path"

    # --- durability: what the client asks for, and what it is told --------
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

    # The commit itself has to be a file-level one: sync(2) is not a durability
    # barrier for NFS - there is no ->sync_fs, and the async flusher usually
    # writes the pages out unstably before the sync writeback reaches them.
    # fdatasync(2) writes back and then COMMITs, and the client only drops the
    # pages when the commit reply's verifier matches the one the write carried.
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
        "the bcachefs backend did not honour a FILE_SYNC write"
    assert counter("ds_last_committed") == 2, \
        "the last write reported committed=%d, expected FILE_SYNC" % \
        counter("ds_last_committed")
    assert ds_counter("write_file_sync") > srv_filesync1, \
        "the server did not record a FILE_SYNC write"
    assert write_verf() == verf_before_crash, \
        "the write verifier changed within one server session"

    # --- a codec bcachefs stores but does not register --------------------
    # The authority over what is served encoded is the codec table, not the
    # backend's numbering: bcachefs stores lz4 extents too, and its number is a
    # perfectly valid descriptor value, but only zstd is registered, so an lz4
    # extent must come back as "not served encoded" and read through the MDS.
    io_before = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])
    server.succeed("touch /srv/export/lz4.bin")
    server.succeed("bcachefs set-file-option --compression=lz4 /srv/export/lz4.bin")
    prop = server.succeed("bcachefs get-file-option /srv/export/lz4.bin 2>&1")
    server.log("lz4.bin file options: %s" % prop.strip())
    server.succeed("dd if=/dev/zero of=/srv/export/lz4.bin bs=1M count=4 2>/dev/null")
    server.succeed("sync")
    ldg = server.succeed("sha256sum /srv/export/lz4.bin").split()[0]
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    rc, out = client.execute(
        "echo '%s  /mnt/lz4.bin' | sha256sum -c - 2>&1" % ldg)
    client.log("read lz4.bin rc=%d out=%s" % (rc, out))
    assert rc == 0, "read of the lz4 file failed: %s" % out
    io_after = int(server.succeed("grep '^io ' /proc/net/rpc/nfsd").split()[1])

    cunk = ds_counter("codec_unknown")
    client.log("lz4 extent: server codec_unknown=%d, client not_encoded=%d, "
               "nfsd read %d -> %d bytes" %
               (cunk, counter("ds_read_not_encoded"), io_before, io_after))
    assert cunk >= 1, \
        "the lz4 extent was not refused by the codec table (codec_unknown=%d): " \
        "the table is not what decides" % cunk
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

    # --- two backends at once ---------------------------------------------
    # btrfs is a codec provider loaded on this same client, with the bcachefs
    # export still mounted: which codec a file is offered is a property of the
    # filesystem it is on, so a layout that named a merged list would have the
    # client compressing with one backend's codec and the other backend
    # refusing it - every write falling back, silently and correctly, which is
    # exactly the kind of thing only a test that looks at the layout notices.
    def codec_names():
        out = client.succeed(
            "cat /sys/kernel/debug/pnfs_bcachefs/codec_names")
        return [l.split(None, 1)[1] for l in out.splitlines() if l.strip()]

    # The btrfs file, reached by crossing the mount inside the bcachefs export.
    # The reference digest comes from the disk, and the read has to come from
    # the data service: nothing but the btrfs backend can serve this file.
    bdigest = sha256_on(server, "/srv/export/btrfs/btrfs.bin")
    drok_before = counter("ds_read_ok")
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    rc, out = client.execute(
        "echo '%s  /mnt/btrfs/btrfs.bin' | sha256sum -c - 2>&1" % bdigest)
    names = codec_names()
    client.log("cross-backend: read of the btrfs file rc=%d, layout codecs %s, "
               "ds_read_ok %d -> %d, requests %d" %
               (rc, names, drok_before, counter("ds_read_ok"),
                counter("codec_requests")))
    assert rc == 0, "reading the second filesystem's file failed: %s" % out
    assert names == ["zstd"], \
        "a btrfs file's layout named %s, not its own filesystem's codec" % names
    assert counter("ds_read_ok") > drok_before, \
        "the btrfs file was not served by the data service"
    # Its codec provider was loaded on demand, on a client that already had the
    # other backend's.
    client.succeed("grep -qw btrfs_encoded_extent_ops /proc/kallsyms")
    assert counter("codec_requests") >= 2, \
        "the client never asked for the second codec's provider module"

    # The bcachefs export, untouched by any of that: its own codec, and only it.
    assert sha256_on(client, "/mnt/zeros.bin") == \
           sha256_on(server, "/srv/export/zeros.bin")
    names = codec_names()
    client.log("cross-backend: read of the bcachefs file, layout codecs %s" %
               names)
    assert names == ["bcachefs-zstd"], \
        "a bcachefs file's layout named %s" % names

    # And a write to the second filesystem, because the layout's list is what
    # the client picks its encoder from: with a merged list it would have
    # compressed with the codec the other backend implements.
    wok_before = counter("ds_write_ok")
    client.succeed("head -c 2097152 /dev/zero | tr '\\000' 'R' > "
                   "/mnt/btrfs/from-client.bin")
    client.succeed("sync -d /mnt/btrfs/from-client.bin")
    cdigest = sha256_on(client, "/mnt/btrfs/from-client.bin")
    sdigest = disk_digest("/srv/export/btrfs/from-client.bin")
    client.log("cross-backend: write to the btrfs file, codecs %s, "
               "ds_write_ok %d -> %d" %
               (codec_names(), wok_before, counter("ds_write_ok")))
    assert cdigest == sdigest, "the write to the second filesystem is not intact"
    assert codec_names() == ["zstd"], \
        "the write's layout was not the second filesystem's codec list"
    assert counter("ds_write_ok") > wok_before, \
        "the write to the second filesystem fell back instead of using the DS"

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

    # A write that is not a whole unit. Every other file this suite writes is a
    # multiple of the write unit - 1 MiB, because the pgio is max(unit_max,
    # wsize) - so the last partial unit has never been tested, and it is the one
    # part of the write path with nowhere to hide: the client encodes a short
    # unit, the service stores it, and the file has to come back the length it
    # went in.
    client.succeed("head -c 1000003 /dev/zero > /mnt/odd.bin")
    client.succeed("sync")
    csize = client.succeed("stat -c %s /mnt/odd.bin").strip()
    ssize = server.succeed("stat -c %s /srv/export/odd.bin").strip()
    client.log("partial unit: wrote 1000003 bytes; client sees %s, server sees %s"
               % (csize, ssize))
    assert csize == "1000003" and ssize == "1000003", \
        "a write whose size is not a whole unit did not keep its tail"

    # And the same thing with data that is not 'P'. The corpus is attached to
    # this node as a read-only raw disk and written into the export with the
    # export's own filesystem, which is how a deployment's data gets there. Its
    # payloads are what make it real: this file encodes 22.7x - the deployment's
    # own data encodes 23.7x - against 30,000x for 'P', so a unit carries tens
    # of KiB instead of hundreds of bytes and the wire, the storage and the
    # codec all stop being free.
    # Written from the client, through the layout: that is the project's own
    # path - the client encodes each unit and the service stores the payload -
    # so the file that ends up on the export really does carry this data's
    # payloads rather than bcachefs's own idea of them.
    client.succeed("cat /dev/disk/by-id/virtio-corpus-test8 > /mnt/real.bin")
    client.succeed("sync")
    rpc0, byt0 = ds_counter("read"), counter("ds_read_bytes")
    client.succeed("echo 3 > /proc/sys/vm/drop_caches")
    real0 = counter("ds_read_ok")
    out = client.succeed("dd if=/mnt/real.bin of=/dev/null bs=1M 2>&1 | tail -1")
    client.log("real data: %s [%d RPCs, %d file bytes, last unit %d B, last "
               "payload %d B]" %
               (out.strip(), ds_counter("read") - rpc0,
                counter("ds_read_bytes") - byt0, counter("ds_last_unit_len"),
                counter("ds_last_payload_len")))
    client.log("real data: corpus device %s bytes, file written %s bytes" % (
        client.succeed("blockdev --getsize64 "
                       "/dev/disk/by-id/virtio-corpus-test8").strip(),
        client.succeed("stat -c %s /mnt/real.bin").strip()))
    assert counter("ds_read_ok") > real0, \
        "the real file's read did not come from the data service"
    assert sha256_on(client, "/mnt/real.bin") == \
        sha256_on(server, "/srv/export/real.bin"), \
        "the real file did not read back as it was stored"
    # What is *not* asserted here, and should be: the payload the wire actually
    # carried. `du` and `st_blocks` cannot say - an encoded extent accounts the
    # logical size, so this file reads as 737 MiB on disk whatever it encodes to
    # - and the only payload figure the driver keeps is the *last* unit's. The
    # corpus compresses 5.1x to 6900x a file (22.7x for this one, against 23.7x
    # for the deployment's own data), so the number is there to be had; it needs
    # a counter on the service, which is the next thing this test wants.

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
    # data service used to stop the *client's* data path (see the wedge arm and
    # doc/gotchas.md 29, which is the fix), and the benchmark should not be the
    # thing that trips over it.
    assert perf_best("read DS  buffered", "dd if=/mnt/perf.bin of=/dev/null "
                     "bs=1M", "read", repeats=1) > 0
    # The benchmark runs that variant once because repeating it used to stop the
    # read (round 17's note, §7.6). That was a failure mode, so it is a test:
    # four more passes, bounded, with the mount's own timeout. The wedge arm,
    # gated, is the long-file version of the same case.
    for _ in range(4):
        client.succeed("echo 3 > /proc/sys/vm/drop_caches; timeout 60 dd "
                       "if=/mnt/perf.bin of=/dev/null bs=1M")
    server.succeed("cat /proc/loadavg")
    client.log("buffered reads through the data path, repeated: still answering")
    assert perf_best("read MDS direct ", "dd if=/mnt3/perf.bin of=/dev/null "
                     "bs=1M iflag=direct", None) > 0
    assert perf_best("read MDS buffered", "dd if=/mnt3/perf.bin of=/dev/null "
                     "bs=1M", None, repeats=1) > 0

    # Writes: a fresh file each time, so each run and each path creates its own
    # extents, and buffered rather than O_DIRECT - a repeated direct write
    # through the data path wedged the server in testing, which is its own bug
    # to chase and not this benchmark's job; if it was the same lost transport,
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
    # The thread count is all of the service's concurrency: a worker blocks for
    # the unit it is serving, from nfsd's own checks through the backend read to
    # the reply, so `inflight_max` can reach it and no further. Whether raising
    # it buys anything is what these numbers say - and whether the service is
    # saturated at all needs throughput to move with it, not just a high-water
    # mark touching it.
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
    gotT = range_digest("/srv/export/shared.bin", 192, 64)
    size = server.succeed("stat -c %s /srv/export/shared.bin").strip()
    client.log("conc shared.bin: size=%s, range 192-256 MiB digest=%s "
               "(want %s), first 64 MiB digest=%s (want %s)" %
               (size, gotT[:16], wantT[:16],
                range_digest("/srv/export/shared.bin", 0, 64)[:16], want64[:16]))
    assert gotT == wantT, \
        "a range no writer touched was changed: size=%s digest=%s want=%s" % \
        (size, gotT[:16], wantT[:16])

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
    # bytes a unit ('P' and zeros), and that hides the one number that decides
    # whether a real filesystem's data can use this path at all: how big an
    # encoded unit is allowed to be. A stored extent is not usually a
    # hundredth of its unit. 192 KiB of urandom plus 64 KiB of zeros per 256 KiB
    # unit stores as a ~192 KiB payload - bigger than a 128 KiB reply buffer
    # could carry, which is a fallback if the client asks for it anyway and a
    # transport error if it asks for more than the reply reserves - and the
    # read still has to come back through the service.
    client.succeed("for i in $(seq 1 16); do head -c 196608 /dev/urandom; "
                   "head -c 65536 /dev/zero; done > /tmp/marginal.bin")
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
    assert counter("ds_last_payload_len") > 131072, \
        "no unit's payload was bigger than the old 128 KiB reply buffer"

    # --- a unit the wire can carry whole ------------------------------------
    # The reply used to go through the RPC client's inline receive buffer, so a
    # unit's encoded payload was bounded by whatever the proc table reserved
    # there - 128 KiB, and then 256 KiB - and the layout's own 256 KiB ceiling
    # hid that. The payload is received into the caller's pages now, so the
    # bound is the wire's 2 MiB and what the caller allocated. This export was
    # formatted with 1 MiB extents and the file stores ~768 KiB payloads a
    # unit: the old inline path could not have carried one at all, so this is
    # the case that says the bound is gone rather than moved.
    client.succeed("for i in $(seq 1 8); do head -c 786432 /dev/urandom; "
                   "head -c 262144 /dev/zero; done > /tmp/big.bin")
    bdigest = client.succeed("sha256sum /tmp/big.bin").split()[0]
    wr1 = ds_counter("write")
    client.succeed("cp /tmp/big.bin /mnt/big/big.bin")
    client.succeed("sync")
    client.log("big unit: wrote through the service %d -> %d calls" %
               (wr1, ds_counter("write")))
    assert ds_counter("write") > wr1, \
        "the big-unit file's write did not go through the data service"
    assert sha256_on(server, "/srv/export/big/big.bin") == bdigest, \
        "the write through the layout did not store what was written"
    drok = counter("ds_read_ok")
    derr = counter("ds_read_err")
    out = client.succeed("echo 3 > /proc/sys/vm/drop_caches; "
                         "sha256sum /mnt/big/big.bin").strip()
    client.log("big unit: read digest=%s, unit_max=%d, ds_read_ok %d -> %d, "
               "ds_read_err %d -> %d, last payload %d bytes" %
               (out.split()[0][:16], counter("unit_max"), drok,
                counter("ds_read_ok"), derr, counter("ds_read_err"),
                counter("ds_last_payload_len")))
    assert out.split()[0] == bdigest, \
        "the big-unit file did not read back as it was written"
    assert counter("unit_max") == 1048576, \
        "the layout did not carry the export's 1 MiB unit (%d)" % \
        counter("unit_max")
    assert counter("ds_read_err") == derr, \
        "the service could not send a unit three quarters of a megabyte long"
    assert counter("ds_read_ok") > drok, \
        "the big-unit file's read did not come from the data service"
    assert counter("ds_last_payload_len") > 262144, \
        "no payload bigger than the old reply buffer crossed the wire"
    # And the write has to leave the inode's block accounting right. The
    # backend's write path reports what an extent did to the file's sector count
    # and its caller applies it - the page cache and direct paths do it in their
    # completions - so a data path that reaches the btree without one has to do
    # it itself. Getting that wrong is invisible in the file's contents and
    # shows up later, when the next thing that takes sectors away (the O_TRUNC
    # every writer opens with, a truncate) underflows against a count that never
    # grew - which bcachefs counts as an fsck error. What a user sees is
    # `stat`: blocks for a file written this way.
    blocks = int(server.succeed("stat -c %b /srv/export/marginal.bin").strip())
    client.log("marginal: server says %d blocks for %d bytes" %
               (blocks, 4 * 1048576))
    assert blocks * 512 == 4 * 1048576, \
        "a file written through the data service is %d blocks, not %d" % \
        (blocks, 4 * 1048576 // 512)

  '' + lib.optionalString walkProbe walkProbeScript
     + lib.optionalString wedgeRepro wedgeArm + ''
    # --- durability: losing the server does not take committed data back ---
    # unstable.bin is committed through an MDS commit of the backend's unstable
    # writes and file-sync.bin through the backend's own fsync; a crash, not a
    # shutdown, must lose neither.
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
    # The emulated device is a systemd unit, so it does not exist the instant
    # the machine answers after a restart; the disk underneath it does. Mount
    # the device the test means, not whichever of the two is up first.
    server.wait_until_succeeds("test -e /dev/mapper/pnfs-data", timeout=120)
    server.succeed("mount -t bcachefs /dev/mapper/pnfs-data /srv/export")
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
    # handed.

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
  '' + lib.optionalString pgUnitsSweep pgUnitsSweepScript;
}

# tree churn probe
