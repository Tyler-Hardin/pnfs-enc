{
  description = "pNFS encoded-extent layout: serve a filesystem's stored compressed extents to clients that decode them - the bcachefs backend";

  inputs = {
    # 6.18 LTS. The kernel patch is generated against this series; see
    # nix/kernel.nix, which refuses to build on anything else.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # The backend: upstream bcachefs-tools at the commit our fork is based on.
    # nix/patches/bcachefs-tools.patch is the delta, regenerated with
    # dev/mkpatch-tools.sh - the module and the userspace tools are the same
    # source tree, which is why this is a source input rather than a package.
    bcachefs-tools = {
      url = "github:koverstreet/bcachefs-tools?ref=v1.39.6";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, bcachefs-tools }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      # One definition of the patched backend source, and one contract: what
      # every module and check receives as `bcachefsToolsSrc` is this tree, with
      # the patch already applied. Anything that takes the *upstream* source and
      # applies the patch itself would apply it twice.
      patched = pkgs: pkgs.applyPatches {
        name = "bcachefs-tools-encoded-extent-src";
        src = bcachefs-tools.outPath;
        patches = [ ./nix/patches/bcachefs-tools.patch ];
      };

      bcachefsTools = {
        src = bcachefs-tools.outPath;
        patch = ./nix/patches/bcachefs-tools.patch;
      };
    in
    {
      # The server module owns the export; the client module owns the mounts.
      # These take the upstream source and the patch, and apply it themselves,
      # so they need no store path from this flake.
      nixosModules.server = import ./nix/modules/server.nix { inherit bcachefsTools; };
      nixosModules.client = import ./nix/modules/client.nix { inherit bcachefsTools; };

      packages = forAllSystems (pkgs:
        let
          src = patched pkgs;
        in
        rec {
          # Exposed because applying the patch to a fetched upstream release is
          # the packaging's one fragile step: this builds in seconds and says
          # whether it still applies, without a kernel or a module.
          bcachefs-tools-src = src;

          kernel = (import ./nix/kernel.nix { inherit pkgs; }).kernel;
          dsprobe = (import ./nix/kernel.nix { inherit pkgs; }).dsprobe;
          bcachefs-module = import ./nix/bcachefs-module.nix {
            inherit pkgs kernel;
            src = src;
          };
          default = kernel;
        });

      # The evidence: two suites that run a server and clients in VMs and check
      # the data path, the failure modes, durability and coherence, plus the
      # module building C-only and with Rust. They boot KVM-accelerated VMs and
      # build a kernel and a bcachefs module, so this is not a fast check -
      # `nix build .#checks.x86_64-linux.bcachefs` is the one that matters.
      checks = forAllSystems (pkgs:
        let
          src = self.packages.${pkgs.stdenv.hostPlatform.system}.bcachefs-tools-src;
          # The bcachefs suite takes the backend source; the btrfs one is the
          # control and takes none.
          bcachefsArgs = { inherit pkgs src; lib = pkgs.lib; profile = "lan"; };
          btrfsArgs = { inherit pkgs; lib = pkgs.lib; profile = "lan"; };
          # The bed the deployment is, from nix/tests/profiles.nix. The kernel
          # is the same derivation for every profile, so a profile is another VM
          # run rather than another build.
          gce = { profile = "gce-network-storage"; };
        in
        {
          btrfs = import ./nix/tests/btrfs.nix btrfsArgs;
          btrfs-gce-network-storage =
            import ./nix/tests/btrfs.nix (btrfsArgs // gce);
          emulation = import ./nix/tests/emulation-check.nix { inherit pkgs; lib = pkgs.lib; };
          # The backend rather than the layout: three devices, fg + bg +
          # promote with durability=0, and the assertion that a read leaves the
          # data on the promote device. It is here because a promote that is
          # refused is silent - see the file's header.
          bcachefs-module-c = import ./nix/checks/bcachefs-module-c.nix { inherit pkgs src; };
          bcachefs-module-rust = import ./nix/checks/bcachefs-module-rust.nix { inherit pkgs src; };
        });
    };
}
