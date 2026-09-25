# Does the emulation emulate? Two nodes, one link, two disks.
#
# Everything in this file is about believing the emulation rather than using it.
# A profile is only useful if the number a test measures is the number the
# profile asked for, so this boots the smallest possible bed - no bcachefs, no
# patched kernel, no data service, so it runs in minutes rather than in a kernel
# build - measures the link and the disks with the emulation off, turns it on,
# and asserts that what came back is what was asked for. The floor it measures
# first is also the harness's own ceiling: what the VMs do when nothing is being
# emulated, which is what a profile has to stay under to mean anything.
#
#   nix build .#checks.x86_64-linux.emulation -L
#
# The tolerances are wide on purpose. `netem`'s rate control is a token bucket
# and it is not precise; a virtualised link's own jitter is not zero; QEMU's
# throttle is a bucket too. What the assertions catch is a knob that does
# nothing, a unit that is off by 8x, or a delay applied to the wrong interface -
# not a 10% disagreement.
{ pkgs, lib }:

let
  # A GCE-shaped network-storage profile: ~0.5 ms one-way, 2 Gbit/s, and a disk
  # that answers a 4k read in about a millisecond. The disk latency is 1 ms
  # rather than the 0.6 ms measured in production because `dm-delay` counts in
  # whole milliseconds; emulation.nix says what to reach for if that granularity
  # ever matters.
  profile = {
    rttMs = 1.0;
    rateMbit = 2000;
    diskLatencyMs = 1;
    diskMBps = 64;
  };

  common =
    { ... }:
    {
      imports = [ ./emulation.nix ];

      environment.systemPackages = [
        pkgs.fio
        pkgs.iperf3
      ];

      networking.firewall.enable = false;

      virtualisation.cores = 4;
      virtualisation.memorySize = 4096;
    };
in
pkgs.testers.nixosTest {
  name = "test-emulation";

  nodes = {
    # `a` is both the measuring instrument and the node with the disks.
    a = { ... }: {
      imports = [ common ];

      virtualisation.testEmulation = {
        link.delayMs = profile.rttMs / 2;
        disks = {
          fast = {
            size = 2048;
          };
          slow = {
            size = 2048;
            latencyMs = profile.diskLatencyMs;
            readMBps = profile.diskMBps;
          };
        };
      };
    };

    # The far end. For the link `b` has to shape too: a round trip is this
    # node's egress plus the peer's, and netem shapes egress.
    b = { ... }: {
      imports = [ common ];

      virtualisation.testEmulation.link.delayMs = profile.rttMs / 2;
    };
  };

  # The profile crosses into the test script as data, from the one definition
  # above, so the assertions cannot drift from what the nodes were configured
  # with.
  testScript = ''
    import json

    profile = {
        "rttMs": ${toString profile.rttMs},
        "rateMbit": ${toString profile.rateMbit},
        "diskLatencyMs": ${toString profile.diskLatencyMs},
        "diskMBps": ${toString profile.diskMBps},
    }

    # `log` is the driver's own logger in this scope, so the helper is `note`.
    def note(line):
        log.info("emulation: %s" % line)

    def ping_rtt(host="b", count=20):
        out = a.succeed("ping -c %d -q -i 0.2 -W 2 %s | tail -1" % (count, host))
        # rtt min/avg/max/mdev = 0.123/0.456/0.789/0.100 ms
        return float(out.split("=")[1].strip().split("/")[1])

    def ping_loss(host="b", count=100, interval="0.1"):
        out = a.succeed("ping -c %d -q -i %s -W 2 %s || true" % (count, interval, host))
        for word in out.replace(",", " ").split():
            if word.endswith("%"):
                return float(word[:-1])
        raise Exception("no loss figure in: %s" % out)

    def iperf_mbit(parallel=1):
        out = a.succeed("iperf3 -c b -t 3 -P %d -J" % parallel)
        return json.loads(out)["end"]["sum_received"]["bits_per_second"] / 1e6

    def fio(dev, rw, bs, iodepth, runtime=4):
        args = ("--name=x --filename=%s --direct=1 --rw=%s --bs=%s --iodepth=%d "
                "--ioengine=libaio --group_reporting --output-format=json "
                "--time_based --runtime=%d" % (dev, rw, bs, iodepth, runtime))
        return json.loads(a.succeed("fio %s" % args))["jobs"][0]

    def fill(dev):
        a.succeed("fio --name=x --filename=%s --direct=1 --rw=write --bs=1M "
                  "--size=512M --group_reporting >/dev/null 2>&1" % dev)

    def set_link(delay, jitter=0, loss=0, rate=0):
        # Both ends, because both directions are shaped on the sender's egress.
        for m in (a, b):
            m.succeed("emulation-link %s %s %s %s" % (delay, jitter, loss, rate))

    start_all()
    a.wait_for_unit("multi-user.target")
    b.wait_for_unit("multi-user.target")

    # --- the link ---------------------------------------------------------

    # The boot-time profile is on the link already: the module applied
    # `rttMs / 2` at each end. Measure it, take it off, measure the floor. The
    # floor is both the delta's baseline and this harness's own ceiling.
    # The throughput server has to be up before the floor is measured.
    b.succeed("systemd-run --unit=iperf3 iperf3 -s")
    b.wait_for_unit("iperf3.service")

    rtt_boot = ping_rtt()
    set_link(0)
    rtt_floor = ping_rtt()
    floor_mbps = iperf_mbit()
    note("link: boot rtt %.3f ms, floor rtt %.3f ms, asked for %.1f ms"
        % (rtt_boot, rtt_floor, profile["rttMs"]))
    note("link: unshaped tcp throughput, i.e. this harness's ceiling: %.0f Mbit/s"
        % floor_mbps)
    assert abs((rtt_boot - rtt_floor) - profile["rttMs"]) < 1.5, (
        "the boot-time delay is not on the link: %.3f ms measured, %.1f asked"
        % (rtt_boot - rtt_floor, profile["rttMs"]))
    # A profile that asks for more than the bed can carry measures the bed, not
    # the profile, and reads as "the cap did not bite".
    assert floor_mbps > 1.2 * profile["rateMbit"], (
        "this harness tops out at %.0f Mbit/s, so it cannot emulate a %d Mbit/s link"
        % (floor_mbps, profile["rateMbit"]))

    # A run-time change is what a sweep does, and it has to land as one.
    set_link(5)
    rtt_5 = ping_rtt()
    note("link: rtt with 5 ms one-way at each end: %.3f ms (floor %.3f)"
        % (rtt_5, rtt_floor))
    assert abs((rtt_5 - rtt_floor) - 10.0) < 2.0, (
        "5 ms one-way per end should be 10 ms of rtt, got %.3f" % (rtt_5 - rtt_floor))

    # Rate and delay together, which is what a wide-area link looks like. The
    # contract a shaper can actually keep is a ceiling on saturating goodput,
    # and a single TCP stream over a delay is often not saturating: its own
    # congestion control gives up first, exactly as it would on a real link. So
    # the assertion is on four parallel streams and the single stream is
    # recorded next to it.
    set_link(5, 0, 0, profile["rateMbit"])
    mbps_1 = iperf_mbit()
    mbps_4 = iperf_mbit(parallel=4)
    note("link: %d Mbit/s cap: %.0f Mbit/s one stream, %.0f with four"
        % (profile["rateMbit"], mbps_1, mbps_4))
    assert mbps_4 <= 1.2 * profile["rateMbit"], (
        "asked for a %d Mbit/s ceiling, four streams got %.0f"
        % (profile["rateMbit"], mbps_4))
    assert mbps_4 >= 0.4 * profile["rateMbit"], (
        "asked for %d Mbit/s, four streams only reached %.0f"
        % (profile["rateMbit"], mbps_4))

    # Loss. TCP hides loss behind retransmits, so this is read off ICMP. Loss,
    # like the delay, is per-egress, and both ends are shaped here - so a round
    # trip survives only if both directions do, and 20% a direction is
    # 1 - 0.8^2 = 36% of pings. The window is wide because ICMP over a shaped
    # link is noisy; what it catches is a knob that does nothing.
    set_link(0, 0, 20)
    loss = ping_loss()
    expected_loss = 100.0 * (1.0 - 0.8 * 0.8)
    note("link: icmp loss with 20%% dropped per direction: %.0f%% (composed: %.0f%%)"
        % (loss, expected_loss))
    assert abs(loss - expected_loss) < 15, (
        "20%% per direction should compose to %.0f%% of pings, measured %.0f%%"
        % (expected_loss, loss))

    set_link(0)
    assert abs(ping_rtt() - rtt_floor) < 1.0, "the link did not come back to the floor"

    # --- the disks --------------------------------------------------------

    # `fast` is the same device-mapper path with a zero delay, so it also
    # measures what the mapper costs when it does nothing. `raw` is the virtio
    # device underneath it, which is what that measurement is against.
    raw = "/dev/disk/by-id/virtio-fast"
    fast = "/dev/mapper/fast"
    slow = "/dev/mapper/slow"

    for dev in (raw, fast, slow):
        assert a.succeed("test -e %s && echo yes" % dev).strip() == "yes", \
            "%s is missing" % dev

    # Fill first: a fresh qcow2 reads as holes, and the medium is not what is
    # being measured.
    fill(fast)
    fill(slow)

    def clat_ms(job):
        return job["read"]["clat_ns"]["mean"] / 1e6

    lat_raw = clat_ms(fio(raw, "randread", "4k", 1, runtime=3))
    lat_fast = clat_ms(fio(fast, "randread", "4k", 1, runtime=3))
    lat_slow = clat_ms(fio(slow, "randread", "4k", 1, runtime=3))
    note("disk: 4k random read clat: raw %.3f ms, mapper %.3f ms, %d ms delay %.3f ms"
        % (lat_raw, lat_fast, profile["diskLatencyMs"], lat_slow))
    assert lat_fast < 0.5, "the zero-delay mapper is adding %.3f ms" % lat_fast
    assert abs(lat_slow - profile["diskLatencyMs"]) < 0.4, (
        "asked for %d ms of latency, measured %.3f"
        % (profile["diskLatencyMs"], lat_slow))

    def bw_MBps(job):
        return job["read"]["bw_bytes"] / 1e6

    bw_raw = bw_MBps(fio(raw, "read", "1M", 8))
    bw_fast = bw_MBps(fio(fast, "read", "1M", 8))
    bw_slow = bw_MBps(fio(slow, "read", "1M", 8))
    note("disk: 1M sequential read: raw %.0f MB/s, mapper %.0f MB/s, capped at %d => %.0f MB/s"
        % (bw_raw, bw_fast, profile["diskMBps"], bw_slow))
    assert 0.75 * profile["diskMBps"] <= bw_slow <= 1.2 * profile["diskMBps"], (
        "asked for a %d MB/s cap, measured %.0f" % (profile["diskMBps"], bw_slow))
    assert bw_slow < 0.5 * bw_fast, (
        "the cap is not biting: %.0f capped against %.0f uncapped" % (bw_slow, bw_fast))

    note("harness ceiling, nothing emulated: rtt %.3f ms, raw disk %.0f MB/s, %.3f ms per 4k"
        % (rtt_floor, bw_raw, lat_raw))
  '';
}
