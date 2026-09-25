# A network and a disk that the VM does not have.
#
# A test bed whose link is a host-local VDE switch and whose disk is a qcow2
# file on the same host measures a machine that exists nowhere: no round trip,
# no link rate, no storage latency. Every number this project has produced so
# far is from that machine, which is why "pipelining is not worth it" had to be
# re-examined the first time it met a real deployment. This module is how a test
# asks for the link and the disk a deployment actually has.
#
# What does the work is the kernel, not QEMU. QEMU can throttle a drive - bytes
# per second and IOPS, which is what `disks.<name>.readMBps` and `.iops` end up
# as, through `virtualisation.emptyDiskImages.*.driveConfig.driveExtraOpts` -
# but it has no way to make IO take *time*: there is no delay option on any
# block backend. So:
#
#   - the link is shaped with `tc` inside the node (`sch_netem`, built as a
#     module in the test kernel), on the inter-VM interface only;
#   - the disk's latency is a device-mapper `delay` target (`dm_delay`) in front
#     of the virtio disk, so the IO still happens on a real virtio device and
#     only its completion time is emulated.
#
# Both are applied at boot and both are re-applicable at run time: the test
# script can call `emulation-link` and `emulation-disk` to sweep profiles inside
# one boot, which is the point - a profile that takes a two-minute reboot to
# change does not get swept.
#
# Every interface here is the *inter-VM* one (`eth1` by default, the VDE link
# the nodes reach each other over). `eth0` is the test driver's own user-mode
# link and must not be shaped, or the driver loses the machine.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  cfg = config.virtualisation.testEmulation;

  num = n: if builtins.isFloat n then builtins.toString n else toString n;

  # One script, called both at boot and by the test script, so the boot-time
  # profile and a run-time sweep cannot disagree about what `netem` was asked
  # for. Positional: delay(ms) jitter(ms) loss(%) rate(Mbit), each defaulting to
  # the configured value, so `emulation-link 2` changes only the delay.
  link =
    pkgs.writeShellScriptBin "emulation-link"
      ''
        set -eu
        iface=${cfg.link.interface}
        delay=''${1:-${num cfg.link.delayMs}}
        jitter=''${2:-${num cfg.link.jitterMs}}
        loss=''${3:-${num cfg.link.lossPercent}}
        rate=''${4:-${num cfg.link.rateMbit}}

        # The interface is created by udev at boot; the service can get here
        # first.
        for i in $(seq 1 100); do
          ip link show "$iface" >/dev/null 2>&1 && break
          sleep 0.1
        done

        if [ "$delay" = 0 ] && [ "$jitter" = 0 ] && [ "$loss" = 0 ] && [ "$rate" = 0 ]; then
          tc qdisc del dev "$iface" root 2>/dev/null || true
          exit 0
        fi

        args="delay ''${delay}ms"
        [ "$jitter" != 0 ] && args="$args ''${jitter}ms"
        [ "$loss" != 0 ] && args="$args loss ''${loss}%"
        [ "$rate" != 0 ] && args="$args rate ''${rate}mbit"
        # shellcheck disable=SC2086
        tc qdisc replace dev "$iface" root handle 1: netem $args
      '';

  # The delayed device the test script should use. A zero delay is deliberately
  # still a device-mapper device: `delay_bio()` returns DM_MAPIO_REMAPPED before
  # it does any work, so the un-emulated profile costs a remap and nothing else,
  # and every profile has the same device path.
  diskDevice = name: "/dev/mapper/${name}";

  # Same contract as the link helper: the delay may be given as an argument, so
  # a test can re-map a device between measurements. The filesystem on it has to
  # be unmounted first; replacing the table under a mounted filesystem is the
  # caller's way to lose data.
  diskScript = name: d: pkgs.writeShellScriptBin "emulation-disk-${name}" ''
    set -eu
    dev=/dev/disk/by-id/virtio-${d.serial}
    for i in $(seq 1 100); do
      [ -e "$dev" ] && break
      sleep 0.1
    done
    test -e "$dev"

    delay=''${1:-${toString d.latencyMs}}
    sectors=$(${pkgs.util-linux}/bin/blockdev --getsz "$dev")
    ${lib.getBin pkgs.lvm2}/bin/dmsetup remove ${name} 2>/dev/null || true
    # <start> <length> delay <device> <offset> <read delay>; three arguments,
    # which is both directions. Six would be separate read and write devices,
    # nine adds offsets.
    ${lib.getBin pkgs.lvm2}/bin/dmsetup create ${name} --table \
      "0 $sectors delay $dev 0 $delay"

    for i in $(seq 1 100); do
      [ -e ${diskDevice name} ] && break
      sleep 0.1
    done
    test -e ${diskDevice name}
  '';

  diskScripts = lib.mapAttrsToList (name: d: diskScript name d) cfg.disks;

  # Nothing below is installed on a node that is not emulating anything, so
  # importing this module costs a node nothing until it asks for something.
  active =
    cfg.link.delayMs != 0
    || cfg.link.jitterMs != 0
    || cfg.link.lossPercent != 0
    || cfg.link.rateMbit != 0
    || cfg.disks != { };
in
{
  options.virtualisation.testEmulation = {
    link = {
      interface = mkOption {
        type = types.str;
        default = "eth1";
        description = ''
          The interface to shape. This is the inter-VM link; `eth0` is the test
          driver's own channel to the machine and must be left alone.
        '';
      };

      delayMs = mkOption {
        type = types.either types.int types.float;
        default = 0;
        description = ''
          One-way delay added to this node's egress, in milliseconds. A round
          trip over a shaped link is the sum of both ends, so a profile aiming
          at an RTT puts half of it here and half on the peer.
        '';
      };

      jitterMs = mkOption {
        type = types.either types.int types.float;
        default = 0;
        description = "Jitter, in milliseconds.";
      };

      lossPercent = mkOption {
        type = types.either types.int types.float;
        default = 0;
        description = "Packet loss, in percent.";
      };

      rateMbit = mkOption {
        type = types.either types.int types.float;
        default = 0;
        description = ''
          Egress rate in Mbit/s, or 0 for the link's own rate. Like the delay,
          this is one direction on one node.
        '';
      };
    };

    disks = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              size = mkOption {
                type = types.ints.positive;
                example = 4096;
                description = ''
                  Size of the test disk, in MiB. This is
                  {option}`virtualisation.emptyDiskImages`: the module declares
                  the drive, because the drive options are where the bandwidth
                  limit lives.
                '';
              };

              serial = mkOption {
                type = types.str;
                default = name;
                description = ''
                  virtio serial, which is how the test finds the disk
                  (`/dev/disk/by-id/virtio-<serial>`). Defaults to the attribute
                  name.
                '';
              };

              latencyMs = mkOption {
                type = types.ints.unsigned;
                default = 0;
                description = ''
                  Per-IO completion latency, in milliseconds, through the
                  `dm-delay` target. Integer, because that is the target's unit:
                  for sub-millisecond latency use `null_blk` (`completion_nsec`)
                  or `scsi_debug` (`ndelay`) instead, which trade the real
                  virtio device for a RAM-backed one.

                  This is a latency, not a queue: concurrent IOs all wait the
                  same time, so bandwidth still scales with queue depth, the way
                  it does on a real network LUN.
                '';
              };

              readMBps = mkOption {
                type = types.ints.unsigned;
                default = 0;
                description = "Read bandwidth cap in MB/s, or 0 for no cap. Enforced by QEMU on the drive.";
              };

              writeMBps = mkOption {
                type = types.ints.unsigned;
                default = 0;
                description = "Write bandwidth cap in MB/s, or 0 for no cap.";
              };

              iops = mkOption {
                type = types.ints.unsigned;
                default = 0;
                description = "Total IOPS cap, or 0 for no cap.";
              };

              device = mkOption {
                type = types.str;
                readOnly = true;
                default = diskDevice name;
                description = "The device the test should format and mount.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Test disks, by name. Each becomes an
        {option}`virtualisation.emptyDiskImages` entry with its serial and its
        QEMU throttling, and a `dm-delay` device at
        {option}`virtualisation.testEmulation.disks.<name>.device`.
      '';
    };
  };

  config = {
    # The module is inert unless a test asks for something, so a node that
    # imports it but emulates nothing is unchanged apart from a no-op helper.
    virtualisation.emptyDiskImages = lib.mapAttrsToList (name: d: {
      inherit (d) size;
      driveConfig = {
        deviceExtraOpts.serial = d.serial;
        driveExtraOpts = lib.optionalAttrs (d.readMBps > 0) {
          "throttling.bps-read" = toString (d.readMBps * 1024 * 1024);
        } // lib.optionalAttrs (d.writeMBps > 0) {
          "throttling.bps-write" = toString (d.writeMBps * 1024 * 1024);
        } // lib.optionalAttrs (d.iops > 0) {
          "throttling.iops-total" = toString d.iops;
        };
      };
    }) cfg.disks;

    boot.kernelModules = lib.optionals active [
      "sch_netem"
      "sch_tbf"
      "dm_delay"
    ];

    # The helpers are the run-time interface: `emulation-link 2` and
    # `emulation-disk-slow 2` re-apply a profile without a reboot, which is what
    # makes a sweep possible inside one boot.
    environment.systemPackages = [ link ] ++ diskScripts ++ [ pkgs.util-linux (lib.getBin pkgs.lvm2) ];

    systemd.services = lib.mkMerge (
      lib.optional active {
        emulation-link = {
          description = "shape the inter-VM link";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = "${link}/bin/emulation-link ${num cfg.link.delayMs} ${num cfg.link.jitterMs} ${num cfg.link.lossPercent} ${num cfg.link.rateMbit}";
        };
      }
      ++ lib.mapAttrsToList (name: d: {
        "emulation-disk-${name}" = {
          description = "delayed device for ${name}";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-udev-settle.service" ];
          wants = [ "systemd-udev-settle.service" ];
          path = [ pkgs.util-linux (lib.getBin pkgs.lvm2) ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = "${diskScript name d}/bin/emulation-disk-${name}";
        };
      }) cfg.disks
    );
  };
}
