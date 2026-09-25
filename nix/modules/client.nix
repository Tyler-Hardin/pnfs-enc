# The client half: a machine that mounts a server's exports with the
# encoded-extent layout type and does the codec work itself.
#
#   services.pnfsClient = {
#     enable = true;
#     mounts."/mnt/data" = { server = "fileserver"; };
#   };
#
# Two things are required and one is convenient. Required: the patched kernel
# (the layout driver is in fs/nfs) and a codec provider for the codec the
# server's layout names. Convenient: the mount options, which are where the
# easy mistakes are - NFSv4.1 or later for a layout at all, and `write=lazy` for
# the durability behaviour this feature is measured with.
{ bcachefsTools }:
{ config, lib, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption optionalAttrs types;

  cfg = config.services.pnfsClient;

  mountOptions = [ "vers=4.1" "write=lazy" "timeo=20" "retrans=2" "_netdev" ];
in
{
  imports = [ (import ./backend.nix { inherit bcachefsTools; }) ];

  options.services.pnfsClient = {
    enable = mkEnableOption "the pNFS encoded-extent layout driver on this client";

    mounts = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          server = mkOption {
            type = types.str;
            example = "fileserver";
            description = "Server to mount from.";
          };
          export = mkOption {
            type = types.str;
            default = "/";
            description = "Export path on that server, as nfsd names it.";
          };
          options = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Extra mount options, appended to the ones the layout type needs.
            '';
          };
        };
      });
      default = { };
      example = {
        "/mnt/data" = { server = "fileserver"; };
      };
      description = ''
        Filesystems to mount with this layout type. Only mounts of exports that
        advertise the layout get it; everything else behaves as ordinary NFS.
      '';
    };
  };

  config = mkIf cfg.enable {
    # The patched kernel and the codec provider are in ../backend.nix, which the
    # server module imports too. The module is deliberately not in
    # boot.kernelModules: the codec is a *provider*, loaded on demand when a
    # layout names it, and a client that never gets a layout never needs it.
    fileSystems = lib.mapAttrs (mountpoint: m: {
      device = "${m.server}:${m.export}";
      fsType = "nfs4";
      options = mountOptions ++ m.options;
    }) cfg.mounts;
  };
}
