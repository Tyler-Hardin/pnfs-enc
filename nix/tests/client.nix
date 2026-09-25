# The NFS client a *deployment* runs, rather than the one a VM boots with.
#
# The kernel's defaults are a ceiling and neither half is obvious
# (doc/gotchas.md 27): `sunrpc.tcp_slot_table_entries` is 2, so at most two RPCs
# are outstanding per transport - and the data service has a transport of its
# own - while a bdi's `read_ahead_kb` is 128 KB, a window that never has a second
# request ready to fill the slot the first one frees. Neither setting alone does
# anything; together they took an md5sum on the deployment from 28 s to 3.3 s.
#
# Both are options, because a bed that models a deployment has to model its
# client as well as its link and disk, and the two settings are read at
# different times:
#
#   - the slot table is read when a transport is created, so it is a kernel
#     parameter or a boot-time sysctl and a runtime write does not touch a
#     transport that already exists;
#   - a bdi is created per superblock, so the readahead window is re-applied on
#     a timer as well as at boot, which is what the deployment's own
#     configuration does.
{ config, lib, ... }:

let
  inherit (lib) mkIf mkOption types;

  cfg = config.virtualisation.testClient;
in
{
  options.virtualisation.testClient = {
    tcpSlotTableEntries = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 32;
      description = ''
        `sunrpc.tcp_slot_table_entries`, set at boot. Null leaves the kernel's
        default of two.
      '';
    };

    readAheadKB = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 65536;
      description = ''
        The readahead window to give NFS's bdis, in KB. Null leaves the kernel's
        default of 128.
      '';
    };

    bdiGlob = mkOption {
      type = types.str;
      default = "/sys/class/bdi/0:*";
      description = ''
        Which bdis to set it on. `0:*` is where NFS puts a superblock it has no
        device number for.
      '';
    };
  };

  config = lib.mkMerge [
    (mkIf (cfg.tcpSlotTableEntries != null) {
      boot.kernel.sysctl."sunrpc.tcp_slot_table_entries" = cfg.tcpSlotTableEntries;
    })

    (mkIf (cfg.readAheadKB != null) {
      systemd.services.nfs-readahead = {
        description = "Raise the readahead window on this host's NFS mounts";
        wantedBy = [ "multi-user.target" ];
        # A bdi appears when its superblock is mounted, so a run at boot misses
        # everything mounted later - which is every mount on a machine that is
        # already up, and every mount in a test.
        startAt = "*-*-* *:*:00/15";
        serviceConfig.Type = "oneshot";
        script = ''
          for b in ${cfg.bdiGlob}; do
            [ -e "$b/read_ahead_kb" ] || continue
            echo ${toString cfg.readAheadKB} > "$b/read_ahead_kb" || true
          done
        '';
      };
    })
  ];
}
