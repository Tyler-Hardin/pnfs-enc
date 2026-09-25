# The link and the disk a suite should measure.
#
# A profile answers "what machine is this run about?". By default the beds in
# this repository are a VDE switch on the host and a qcow2 file in that host's
# page cache: no round trip, no link rate, no storage latency, and so no
# relation to the deployment this project is for. `nix/tests/emulation.nix` is
# the machinery that fixes that; this file is the table of machines to point it
# at.
#
# `client` is the NFS client to run, from nix/tests/client.nix; `lan` names none
# and so keeps the kernel's own settings, which makes it their control too.
# `clientCores` is how many vCPUs the reader gets, for the same reason.
#
# Every value is *per node's egress* for the link - a round trip is half at each
# end, because netem shapes egress - and for the server's export disk, which is
# where the encoded extents live. Zero means "leave it alone".
#
# These are not measurements of the deployment. They are its shape with the
# arithmetic written down, so that a disagreement is about a number rather than
# about what was meant. Two of the numbers are reasoned rather than measured:
#
#   - the link rate is 0 on the GCE profiles. That region's link carries more
#     than this bed can: doc/development.md measures the floor at ~2.9 Gbit/s, and
#     570 MB/s of single-stream data-path reads is 4.6 Gbit/s. Shaping it would
#     measure the bed.
#   - pd-balanced's throughput is 570 MB/s because a 2 TB pd-balanced volume is
#     provisioned at roughly 0.28 MB/s per GB, which is the same 570 MB/s the
#     deployment's single reader measured - so the storage, not the link, is
#     what those numbers were up against.
{
  lan = {
    description = "the test bed as it is: no link emulation, a qcow2 disk in the host's page cache";
    rttMs = 0;
    rateMbit = 0;
    diskLatencyMs = 0;
    diskMBps = 0;
  };

  gce-network-storage = {
    description = "a GCE VM with pd-balanced over the network: 0.5 ms rtt, ~1 ms storage, 570 MB/s";
    rttMs = 0.5;
    rateMbit = 0;
    diskLatencyMs = 1;
    diskMBps = 570;
    # The reader is a 4-vCPU VM. The test bed's nodes are 12 by default,
    # which flatters a single stream by three times if the client is what
    # limits it - so the deployment profiles say what the deployment has.
    clientCores = 4;
    # And the client those VMs run, from the deployment's own configuration: the
    # kernel's defaults are two slots and 128 KB of readahead, which
    # doc/gotchas.md 27 is about, and neither alone does anything.
    client = {
      tcpSlotTableEntries = 32;
      readAheadKB = 65536;
    };
  };

  gce-local-nvme = {
    description = "a GCE VM whose export is on local NVMe: 0.5 ms rtt, no storage latency, no cap";
    rttMs = 0.5;
    rateMbit = 0;
    diskLatencyMs = 0;
    diskMBps = 0;
    # The reader is a 4-vCPU VM. The test bed's nodes are 12 by default,
    # which flatters a single stream by three times if the client is what
    # limits it - so the deployment profiles say what the deployment has.
    clientCores = 4;
    # And the client those VMs run, from the deployment's own configuration: the
    # kernel's defaults are two slots and 128 KB of readahead, which
    # doc/gotchas.md 27 is about, and neither alone does anything.
    client = {
      tcpSlotTableEntries = 32;
      readAheadKB = 65536;
    };
  };

  wan-network-storage = {
    description = "a client across the internet from the same storage: 20 ms rtt, 200 Mbit/s";
    rttMs = 20;
    rateMbit = 200;
    diskLatencyMs = 1;
    diskMBps = 570;
    # The reader is a 4-vCPU VM. The test bed's nodes are 12 by default,
    # which flatters a single stream by three times if the client is what
    # limits it - so the deployment profiles say what the deployment has.
    clientCores = 4;
    # And the client those VMs run, from the deployment's own configuration: the
    # kernel's defaults are two slots and 128 KB of readahead, which
    # doc/gotchas.md 27 is about, and neither alone does anything.
    client = {
      tcpSlotTableEntries = 32;
      readAheadKB = 65536;
    };
  };
}
