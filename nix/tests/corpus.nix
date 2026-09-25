# The benchmark corpus, attached to a guest as read-only raw disks.
#
# The files live in the repository (`nix/tests/data`, LFS-tracked, anonymised
# real data - the README beside them says what they are) and there are 7.3 GB of
# them, which makes *how they reach the store* the important part:
#
#   - Nix copies a flake's source into the store once. With
#     `auto-optimise-store` - the NixOS default, and `nix show-config` says
#     whether it is on - every later copy, one per commit or working-tree
#     change, is a hardlink to that same inode: a hundred commits cost one copy
#     and a hundred directory entries. Without it each commit costs a real
#     7.3 GB, which is worth checking before adding a file to the corpus.
#   - Nothing copies them. A `runCommand` that staged them, or a node image that
#     contained them, would be a second real 7.3 GB per node. The drives below
#     are `-drive file=<store path>,readonly=on`, which QEMU opens where it is,
#     so the guest reads a block device and nothing is duplicated.
#
# One read-only raw disk per file, named the way the suites already name their
# data disks, so a test reads one with `dd`:
#
#   /dev/disk/by-id/virtio-corpus-test1
#
# which is also how a deployment's data gets into its export in the first place:
# written by the filesystem that owns it, not through the layout.
{ config, lib, ... }:

let
  inherit (lib) mkOption types;

  cfg = config.virtualisation.testCorpus;

  # Every .bin in the directory unless a subset is named, so adding a file to
  # the corpus is enough to make it available to a test.
  files =
    if cfg.files != [ ] then
      cfg.files
    else
      lib.filter (n: lib.hasSuffix ".bin" n) (lib.attrNames (builtins.readDir cfg.dir));
in
{
  options.virtualisation.testCorpus = {
    dir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = lib.literalExpression "./data";
      description = ''
        Directory holding the corpus, or null to attach nothing.
      '';
    };

    files = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Which of its files to attach, by basename. The default is every `.bin`
        in {option}`virtualisation.testCorpus.dir`.
      '';
    };
  };

  config = lib.mkIf (cfg.dir != null) {
    virtualisation.qemu.drives = map (f: {
      file = "${cfg.dir}/${f}";
      driveExtraOpts = {
        format = "raw";
        readonly = "on";
      };
      deviceExtraOpts.serial = "corpus-" + lib.removeSuffix ".bin" f;
    }) files;
  };
}
