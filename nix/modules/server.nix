# The server half: an NFS server whose bcachefs exports offer the
# encoded-extent layout type, plus the data service the layout points clients
# at. Everything else about the export - namespace, attributes, coherence,
# locking, recovery - is stock nfsd.
#
#   services.pnfsServer.enable = true;
#
# The filesystem itself is not managed here: the data service serves whatever
# the export resolves to, so the export path has to be a mounted bcachefs
# filesystem, set up however you normally mount one.
{ bcachefsTools }:
{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optional types;

  cfg = config.services.pnfsServer;

  # fsid is per-export, not global, and has to be on the export line: nfsd
  # identifies an export by it, and the data service resolves the file handles
  # clients present through nfsd's own export lookup.
  exportOptions = cfg.exportOptions ++ [ "fsid=${toString cfg.fsid}" ];

  exportLine = "${cfg.export} " + lib.concatMapStringsSep " " (
    client: "${client}(${lib.concatStringsSep "," exportOptions})"
  ) cfg.clients;
in
{
  imports = [ (import ./backend.nix { inherit bcachefsTools; }) ];

  options.services.pnfsServer = {
    enable = mkEnableOption "the pNFS encoded-extent data service and its exports";

    export = mkOption {
      type = types.path;
      default = "/srv/export";
      example = "/srv/export";
      description = ''
        Path, on this server, that clients reach as the root of the export. It
        has to be the mount point of the bcachefs filesystem that should serve
        encoded extents: the data service resolves file handles against it with
        nfsd's own verification, so an export outside a bcachefs filesystem
        simply never offers the layout.
      '';
    };

    clients = mkOption {
      type = types.listOf types.str;
      default = [ "*" ];
      example = [ "10.0.0.0/24" ];
      description = "Clients the export is offered to, in exports(5) syntax.";
    };

    fsid = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = ''
        The export's fsid. Each export of a different filesystem needs its own.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 2050;
      description = ''
        TCP port the data service listens on, fixed in the layout handed to
        clients and read by clients from there. It is a kernel parameter
        (`nfsd.encoded_ds_port`), so changing it needs a reboot.
      '';
    };

    threads = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 32;
      description = ''
        Worker threads the data service runs, and so the number of backend
        calls it can have in flight at once. `null` leaves the service's own
        default of eight. A wide workload saturates at this number - the
        service's `inflight_max` counter in
        /sys/kernel/debug/encoded_ds/inflight_max is what shows it - so a
        server with many cores wants it raised. It is a kernel parameter
        (`nfsd.encoded_ds_nthreads`).
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the data service's port. This is not nfsd's port: the service is a
        separate RPC program on its own listener, so nfsd's own firewall
        handling does not cover it.
      '';
    };

    exportOptions = mkOption {
      type = types.listOf types.str;
      default = [ "rw" "no_subtree_check" "crossmnt" "pnfs" "no_root_squash" "insecure" ];
      description = ''
        Export options for {option}`services.pnfsServer.export`, and the ones
        the feature is verified with. `pnfs` is what makes nfsd offer a layout
        at all. `no_root_squash` and `insecure` are the test configuration:
        tighten them to match your export policy, remembering that the data
        service opens files with the client's own credentials, so squashing
        root stops a root client writing to root-owned files exactly as the MDS
        would.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The kernel, the codec module and dsprobe are in ../backend.nix, which the
    # client module imports too. What is left here is the server's own half: the
    # export mounts the filesystem, so the module is loaded from boot, and the
    # kernel parameters below belong to the object it is linked into.
    boot.kernelModules = [ "bcachefs" ];
    boot.kernelParams = [
      "nfsd.encoded_ds_port=${toString cfg.port}"
    ] ++ optional (cfg.threads != null) "nfsd.encoded_ds_nthreads=${toString cfg.threads}";

    services.nfs.server.enable = true;
    # mkAfter, not a replacement: this is one more export, and any others the
    # host defines (including other bcachefs filesystems with their own fsid)
    # stay where they are.
    services.nfs.server.exports = lib.mkAfter ''
      ${exportLine}
    '';

    networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.port;

    assertions = [
      {
        assertion = lib.elem "pnfs" cfg.exportOptions;
        message = "services.pnfsServer.exportOptions must contain \"pnfs\", or nfsd offers no layout for the export.";
      }
    ];
  };
}
