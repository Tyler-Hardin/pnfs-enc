# Does promote_on_write put a new write on the promote target, before any read?
#
#   nix build --impure --expr '(import ./nix/tests/promote-on-write.nix { ... })' -L
#
# Two devices, fg (durable) + promote (durability 0), in the documented
# writearound setup: foreground_target=fg, promote_target=promote.  Without the
# mount option a write lands only on fg, and a promote waits for a read - that
# is what promote.nix covers.  With it the same write also leaves a cached copy
# on promote, in the same write operation.  The copy is cached and durability 0,
# so it is never the safe copy (fg still is), and a promote that cannot be
# allocated is skipped rather than failing the write.
#
# It needs its own test because the symptom is silent.  A write-time cached copy
# that never happened looks exactly like one that was evicted by the next
# allocation, and none of the promote counters move either way.  So the
# assertion is on the promote device's own usage, and on data_read_promote not
# moving - nothing here reads the data before that point, so a copy that showed
# up cannot have come from the read path.  The default (no option) is checked
# first as the control that makes the second write mean something.
{ pkgs, lib, src ? ../../bcachefs-tools }:

let
  kernel = (import ../kernel.nix { inherit pkgs; }).kernel;

  bcachefsModule = import ../bcachefs-module.nix {
    inherit pkgs lib kernel src;
    rust = true;
  };
in
pkgs.testers.nixosTest {
  name = "bcachefs-promote-on-write";

  nodes.machine = { ... }: {
    imports = [ ./emulation.nix ];

    boot.kernelPackages = pkgs.linuxPackagesFor kernel;
    boot.extraModulePackages = [ bcachefsModule ];
    boot.kernelModules = [ "bcachefs" ];
    environment.systemPackages = [ pkgs.bcachefs-tools ];

    virtualisation.cores = 4;
    virtualisation.memorySize = 4096;
    virtualisation.testEmulation.disks = {
      fg = { size = 1024; };
      promote = { size = 1024; };
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /mnt")

    # --durability=0 is sticky from where it is given, so promote comes last.
    machine.succeed(
        "bcachefs format --force "
        "--label=fg /dev/mapper/fg "
        "--label=promote --durability=0 /dev/mapper/promote "
        "--foreground_target=fg --promote_target=promote")

    # A pattern the write path cannot compress away and that can be compared
    # after a readback.  Kept on the root filesystem, not on the test filesystem.
    machine.succeed("dd if=/dev/urandom of=/tmp/pattern.bin bs=1M count=64 status=none")

    def promote_line():
        out = machine.succeed("bcachefs fs usage -h /mnt")
        for line in out.splitlines():
            if line.startswith("promote "):
                return line.strip()
        raise Exception("no promote device line in fs usage:\n" + out)

    def counters():
        out = machine.succeed(
            "for f in /sys/fs/bcachefs/*/counters/*; do "
            "printf '%s=' $(basename $f); head -1 $f | cut -f2; done")
        return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)

    def print_promote_counters(tag, c):
        for name in sorted(c):
            if "promote" in name:
                print("%s: %s = %s" % (tag, name, c[name]))

    # 1. The default: no promote_on_write, so the write stays on fg.  This is
    #    the writearound behaviour, and the control that makes step 2 mean
    #    something.
    machine.succeed("mount -t bcachefs /dev/mapper/fg:/dev/mapper/promote /mnt")
    before = promote_line()
    before_counters = counters()
    print_promote_counters("before the writearound write", before_counters)

    machine.succeed("cp /tmp/pattern.bin /mnt/writearound.bin")
    machine.succeed("sync")
    writearound = promote_line()
    print("promote device after a write without promote_on_write:\n  %s" % writearound)
    assert writearound == before, \
        "a write reached the promote device without promote_on_write:\n" \
        "  before: %s\n  after:  %s" % (before, writearound)
    machine.succeed("umount /mnt")

    # 2. With promote_on_write the same write also writes a cached copy to the
    #    promote target.  Nothing reads the file before the assertions, so the
    #    only way the copy can exist is the write path.
    machine.succeed("mount -t bcachefs -o promote_on_write "
                    "/dev/mapper/fg:/dev/mapper/promote /mnt")
    before = promote_line()
    before_counters = counters()
    print_promote_counters("before the promote-on-write write", before_counters)

    machine.succeed("cp /tmp/pattern.bin /mnt/promote-on-write.bin")
    machine.succeed("sync")
    after = promote_line()
    after_counters = counters()
    print("promote device after the same write with promote_on_write:\n  %s" % after)
    print_promote_counters("after the promote-on-write write", after_counters)
    print("usage, after both writes:\n" + machine.succeed("bcachefs fs usage -h /mnt"))

    assert after != before, \
        "promote_on_write wrote nothing to the promote device:\n  %s" % after
    assert after_counters["data_read_promote"] == before_counters["data_read_promote"], \
        "data_read_promote moved (%s -> %s) with no read: the copy did not come " \
        "from the write path" % (before_counters["data_read_promote"],
                                 after_counters["data_read_promote"])

    # And the bytes are still readable after the cached copy is the only
    # candidate the read path would want.  This read may promote again (there is
    # nothing left to promote), so it comes after the counter assertion.
    machine.succeed("echo 3 > /proc/sys/vm/drop_caches")
    machine.succeed("cmp /tmp/pattern.bin /mnt/promote-on-write.bin")
    machine.succeed("umount /mnt")

    # 3. The behaviour promote_on_write generalizes, and the reason it is a
    #    separate option rather than always-on: a durability 0 device in the
    #    *foreground* target already gets a cached copy on every write, with no
    #    option at all ("true writethrough caching" in the bcachefs docs).  So a
    #    deployment willing to put its cache in the foreground group needs no
    #    patch - the option is for keeping the cache a separate promote target,
    #    and for being able to turn the write half off.  Device 1 is the
    #    durability 0 one; it is labelled fg here, like device 0.
    machine.succeed(
        "bcachefs format --force "
        "--label=fg /dev/mapper/fg "
        "--label=fg --durability=0 /dev/mapper/promote "
        "--foreground_target=fg")
    machine.succeed("mount -t bcachefs /dev/mapper/fg:/dev/mapper/promote /mnt")

    def device_line(idx):
        out = machine.succeed("bcachefs fs usage -h /mnt")
        for line in out.splitlines():
            if "(device %d)" % idx in line:
                return line.strip()
        raise Exception("no device %d line in fs usage:\n" % idx + out)

    before = device_line(1)
    machine.succeed("cp /tmp/pattern.bin /mnt/same-target.bin")
    machine.succeed("sync")
    after = device_line(1)
    print("durability 0 device in the foreground target, before:\n  %s\n  after:\n  %s"
          % (before, after))
    assert after != before, \
        "a durability 0 device in the foreground target got no write-time " \
        "cached copy, so promote_on_write is not the same-target case made " \
        "separable:\n  %s" % after
  '';
}
