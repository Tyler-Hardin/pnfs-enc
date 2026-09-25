# Does bcachefs actually promote data to the promote target when it is read?
#
#   nix build --impure --expr '(import ./nix/tests/promote.nix { ... })' -L
#
# Three devices, fg + bg + promote, with durability=0 only on promote: writes
# land on fg, the reconcile machinery moves them to bg, and reading data that is
# not on the promote target is supposed to leave a cached copy there.
#
# Worth a test of its own because promote fails silently. It is gated three
# times over - the inode's `promote_target` option, the read's
# `BCH_READ_may_promote` flag, and `should_promote()` (already promoted /
# unwritten / target congested) - and only the last three are counted, so "the
# inode never had the option" and "the promote happened and was dropped" look
# the same from the outside. Every counter is printed; the assertion is on
# `data_read_promote`, and the nopromote counters say which gate said no.
{ pkgs, lib, src ? ../../bcachefs-tools, promoteDurability ? 0 }:

let
  kernel = (import ../kernel.nix { inherit pkgs; }).kernel;

  bcachefsModule = import ../bcachefs-module.nix {
    inherit pkgs lib kernel src;
    rust = true;
  };
in
pkgs.testers.nixosTest {
  name = "bcachefs-promote";

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
      bg = { size = 1024; };
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
        "--label=bg /dev/mapper/bg "
        "--label=promote --durability=${toString promoteDurability} /dev/mapper/promote "
        "--foreground_target=fg --background_target=bg --promote_target=promote")
    machine.succeed("mount -t bcachefs "
                    "/dev/mapper/fg:/dev/mapper/bg:/dev/mapper/promote /mnt")
    print("superblock of the promote device:\n" +
          machine.succeed("bcachefs show-super /dev/mapper/promote | head -30"))
    print("usage, empty filesystem:\n" + machine.succeed("bcachefs fs usage -h /mnt"))

    # Pattern data, not zeroes, so nothing here is a hole or a compression
    # question: this test is about where the bytes end up.
    machine.succeed("set -o pipefail; head -c 512M /dev/zero | tr '\\000' 'P' > /mnt/data.bin")
    machine.succeed("sync")
    # Let the foreground-to-background move finish: that is the state a promote
    # acts on (the data is somewhere that is not the promote target).
    machine.succeed("bcachefs reconcile wait /mnt --types target")
    print("after the write and the move to background:\n" +
          machine.succeed("bcachefs fs usage -h /mnt"))

    def counters():
        out = machine.succeed(
            "for f in /sys/fs/bcachefs/*/counters/*; do "
            "printf '%s=' $(basename $f); head -1 $f | cut -f2; done")
        return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)

    # The line `bcachefs fs usage` prints for the promote device: the symptom
    # this test exists for is that it stays at the superblock and journal, so
    # the assertion is that it moved. The counters cannot show that - a promote
    # that is attempted and then fails to write leaves no trace in them.
    def promote_line():
        out = machine.succeed("bcachefs fs usage -h /mnt")
        for line in out.splitlines():
            if line.startswith("promote "):
                return line.strip()
        raise Exception("no promote device line in fs usage:\n" + out)

    before = counters()
    usage_before = promote_line()
    for name in sorted(before):
        if "promote" in name:
            print("before: %s = %s" % (name, before[name]))
    print("before: %s" % usage_before)

    # Both read paths set BCH_READ_may_promote: O_DIRECT, and buffered with the
    # cache dropped first so the read reaches the device.
    machine.succeed("dd if=/mnt/data.bin of=/dev/null bs=1M iflag=direct")
    machine.succeed("echo 3 > /proc/sys/vm/drop_caches")
    machine.succeed("cat /mnt/data.bin > /dev/null")
    # Promotes are data updates; reconcile is what parks and finishes them.
    machine.succeed("bcachefs reconcile wait /mnt --types target")
    machine.succeed("sync")

    after = counters()
    usage_after = promote_line()
    for name in sorted(after):
        if "promote" in name:
            print("after:  %s = %s" % (name, after[name]))
    print("after:  %s" % usage_after)
    print("usage, after the reads:\n" + machine.succeed("bcachefs fs usage -h /mnt"))

    assert after["data_read_promote"] != before["data_read_promote"], \
        "nothing was promoted: data_read_promote stayed at %s (nopromote " \
        "counters: %s)" % (after["data_read_promote"],
                           {k: v for k, v in after.items()
                            if "nopromote" in k})

    # And the bytes have to land on the promote device, which is the part the
    # counters cannot show.
    assert usage_after != usage_before, \
        "a promote was attempted and the promote device is unchanged: %s" % usage_after
  '';
}
