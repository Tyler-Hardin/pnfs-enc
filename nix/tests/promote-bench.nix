# What does promote_on_write buy on a read-after-write workload, when the
# foreground store is a network-backed SSD and the promote target is local?
#
# This one is a benchmark, not a gate: it prints numbers and asserts only the
# sanity checks it depends on.  Run it directly:
#
#   nix build .#checks.x86_64-linux.promote-bench -L
#
# The bed is nix/tests/emulation.nix, which shapes each disk on its own:
#
#   fg       pd-ssd: 1 ms per IO through dm-delay, 570 MB/s through QEMU
#   promote  local NVMe: no delay, no cap
#
# so the two devices differ the way the deployment's do.  It measures the two
# devices raw first, so the model is visible in the same run as the result; then
# a buffered cold/hot read, to show what the page cache looks like when it *is*
# the thing being measured; then a write-then-read of fresh files with one
# reader (latency-bound, where the 1 ms/IO shows) and with depth (bandwidth-
# bound, where the 570 MB/s cap shows).
#
# The page cache is not an explanation for the result: the measurement reads are
# O_DIRECT and `drop_caches` precedes each one, the bandwidth file is larger than
# the guest's RAM, and the option-off number lands on the raw fg device.  The
# *host* page cache behind QEMU is still in play, and it is why the promote side
# runs at host-memory speed - above a real local SSD - so the bandwidth ratio is
# optimistic.  What the bed cannot model at all is the reason the deployment
# cares: the foreground device is reached over the same network as the NFS
# traffic, so reading it spends a shared budget that a local read does not.
# Both disks here are local virtio devices.  This is the read-path half of the
# benefit; the bandwidth half would need the foreground store to be a network
# block device across the shaped link.
{ pkgs, lib, src ? ../../bcachefs-tools }:

let
  kernel = (import ../kernel.nix { inherit pkgs; }).kernel;

  bcachefsModule = import ../bcachefs-module.nix {
    inherit pkgs lib kernel src;
    rust = true;
  };
in
pkgs.testers.nixosTest {
  name = "bcachefs-promote-bench";

  nodes.machine = { ... }: {
    imports = [ ./emulation.nix ];

    boot.kernelPackages = pkgs.linuxPackagesFor kernel;
    boot.extraModulePackages = [ bcachefsModule ];
    boot.kernelModules = [ "bcachefs" ];
    environment.systemPackages = [ pkgs.bcachefs-tools pkgs.fio ];

    virtualisation.cores = 8;
    # Smaller than the bandwidth file below, deliberately: "it fit in the page
    # cache" must not be an available explanation for any number here.
    virtualisation.memorySize = 1536;
    # The generated file lives on the root filesystem, which has to be able to
    # hold it; the default is 1 GiB.
    virtualisation.diskSize = 8192;
    virtualisation.testEmulation.disks = {
      # The shape of a pd-ssd behind the network: ~1 ms per IO, ~570 MB/s for
      # a 2 TB pd-balanced volume (see nix/tests/profiles.nix).
      fg = { size = 8192; latencyMs = 1; readMBps = 570; writeMBps = 570; };
      # Local NVMe: nothing in front of it.  The bed's fast floor is its own
      # host page cache, which is above a real local SSD.
      promote = { size = 8192; };
    };
  };

  testScript = ''
    import json

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /mnt")

    def fio(path, rw, bs, iodepth, direct=True, size="256M"):
        args = ("--name=x --filename=%s --rw=%s --bs=%s --iodepth=%d "
                "--numjobs=1 --ioengine=libaio --group_reporting "
                "--output-format=json --size=%s" % (path, rw, bs, iodepth, size))
        if direct:
            args += " --direct=1"
        return json.loads(machine.succeed("fio %s" % args))["jobs"][0]

    def bw_MBps(job):
        return job["read"]["bw_bytes"] / 1e6

    # --- the model, measured first ---------------------------------------
    # Raw devices, so the filesystem is not in the way.  What
    # nix/tests/emulation-check.nix asserts; repeated here so a run can be read
    # without trusting another test's.
    for dev in ("fg", "promote"):
        machine.succeed("fio --name=fill --filename=/dev/mapper/%s --direct=1 "
                        "--rw=write --bs=1M --size=1G --group_reporting "
                        ">/dev/null 2>&1" % dev)
    raw_fg = bw_MBps(fio("/dev/mapper/fg", "read", "1M", 8))
    raw_promote = bw_MBps(fio("/dev/mapper/promote", "read", "1M", 8))

    machine.succeed(
        "bcachefs format --force "
        "--label=fg /dev/mapper/fg "
        "--label=promote --durability=0 /dev/mapper/promote "
        "--foreground_target=fg --promote_target=promote")

    BW_MB = 3072     # larger than the guest's RAM: cannot be cached
    LAT_MB = 256     # latency, not bandwidth: size only has to clear the cache
    ITER = 3
    machine.succeed("dd if=/dev/urandom of=/tmp/bw.bin bs=1M count=%d status=none"
                    % BW_MB)
    machine.succeed("dd if=/dev/urandom of=/tmp/lat.bin bs=1M count=%d status=none"
                    % LAT_MB)

    # --- what the page cache looks like, so it can be ruled out -----------
    # A buffered read of a file that does fit, cold then hot: a cache-served
    # read is *this* fast, and the O_DIRECT numbers below are nowhere near the
    # hot one.
    machine.succeed("mount -t bcachefs /dev/mapper/fg:/dev/mapper/promote /mnt")
    machine.succeed("dd if=/dev/urandom of=/mnt/cache.bin bs=1M count=512 status=none")
    machine.succeed("sync")
    machine.succeed("echo 3 > /proc/sys/vm/drop_caches")
    cache_cold = bw_MBps(fio("/mnt/cache.bin", "read", "1M", 8, direct=False, size="512M"))
    cache_hot = bw_MBps(fio("/mnt/cache.bin", "read", "1M", 8, direct=False, size="512M"))
    machine.succeed("rm -f /mnt/cache.bin")
    machine.succeed("sync")
    machine.succeed("umount /mnt")

    print("")
    print("model: raw 1M read, depth 8   fg %6.0f MB/s   promote %6.0f MB/s"
          % (raw_fg, raw_promote))
    print("cache: 512M buffered read     cold %4.0f MB/s   hot     %6.0f MB/s"
          % (cache_cold, cache_hot))

    def run(label, mount_opts):
        machine.succeed("mount -t bcachefs %s "
                        "/dev/mapper/fg:/dev/mapper/promote /mnt" % mount_opts)
        lat, bw = [], []
        for i in range(ITER):
            # One file per measurement, each read exactly once: a read of a file
            # that is only on fg promotes it as a side effect, so a second read
            # of the same file would be local whichever way the option is set.
            latf = "/mnt/lat%d.bin" % i
            bwf = "/mnt/bw%d.bin" % i
            machine.succeed("cp /tmp/lat.bin %s" % latf)
            machine.succeed("cp /tmp/bw.bin %s" % bwf)
            machine.succeed("sync")
            machine.succeed("echo 3 > /proc/sys/vm/drop_caches")
            # Depth 1: the per-IO latency is the whole cost.
            j = fio(latf, "read", "1M", 1, size="%dM" % LAT_MB)
            lat.append(j["read"]["clat_ns"]["mean"] / 1e6)
            machine.succeed("echo 3 > /proc/sys/vm/drop_caches")
            # Depth 32: the cap is the whole cost.
            bw.append(bw_MBps(fio(bwf, "read", "1M", 32, size="%dM" % BW_MB)))
            print("%s: iter %d  1-deep lat %6.3f ms  32-deep %6.0f MB/s"
                  % (label, i, lat[-1], bw[-1]))
            machine.succeed("rm -f %s %s" % (latf, bwf))
            machine.succeed("sync")
        machine.succeed("umount /mnt")
        lat.sort()
        bw.sort()
        return lat[len(lat) // 2], bw[len(bw) // 2]

    # Control: the documented writearound shape.  The first read of each file
    # comes from fg and promotes a copy as a side effect.
    off_lat, off_bw = run("promote_on_write=off", "")
    # The feature: the copy is already local when the read starts.
    on_lat, on_bw = run("promote_on_write=on", "-o promote_on_write")

    print("")
    print("read-after-write, depth 1 : off %6.3f ms, on %6.3f ms, %.1fx"
          % (off_lat, on_lat, off_lat / on_lat))
    print("read-after-write, depth 32: off %6.0f MB/s, on %6.0f MB/s, %.1fx"
          % (off_bw, on_bw, on_bw / off_bw))

    # If these fail, the numbers above are measuring something else: the copy is
    # not local, or the option-off read did not reach fg.
    assert on_lat < 0.5 * off_lat, \
        "promote_on_write=on was not much faster on a single reader"
    assert 0.5 * raw_fg < off_bw < 1.5 * raw_fg, \
        "the option-off read did not land on the raw fg device"
  '';
}
