# The bcachefs kernel module, built from a bcachefs-tools source tree against
# @kernel. The encoded-extent backend lives in that tree (fs/encoded_extent.c
# and the ops it registers), so this is where the server's filesystem and the
# client's codec provider both come from.
#
#   bcachefs-module.nix { pkgs, lib, kernel, src, rust ? true, ccache ? no-op }
#
# @src is a source tree, not a checkout path: the flake passes the pinned
# upstream release with nix/patches/bcachefs-tools.patch applied, and the dev
# loop passes the ./bcachefs-tools checkout, which is the same tree with the
# same commits. Nothing here reaches outside its arguments.
#
# @ccache is the dev loop's compiler cache (dev/ccache.nix); it defaults to a
# no-op so that the packaged build depends on nothing but its inputs.
{ pkgs, kernel, src, rust ? true
, lib ? pkgs.lib
, ccache ? { override = { }; } }:

let
  repo = lib.cleanSource src;
  linuxPackages = pkgs.linuxPackagesFor kernel;

  # What `make install_dkms` stages, minus the userspace build (which comes from
  # nixpkgs): fs/ as src/fs/bcachefs, dkms/Makefile, version.h.
  dkmsSrc = pkgs.runCommand "bcachefs-dkms-src" { } ''
    mkdir -p $out/src/fs/bcachefs
    cp -r ${repo}/fs/. $out/src/fs/bcachefs/
    cp ${repo}/dkms/module-version.c $out/src/fs/bcachefs/
    echo '#define bcachefs_version "pnfs-bcachefs"' > $out/src/fs/bcachefs/version.h
    cp ${repo}/dkms/Makefile $out/Makefile
    touch $out/build.vars
  '';

  # module-build.nix is `bcachefs-tools: {lib, stdenv, ...}: drv`: bind the
  # source first, then let callPackage fill in the kernel-side arguments.
  # stdenv is passed explicitly so the dev loop's cache applies to the C half of
  # the module (the Rust half has its own compiler and is not cached).
  module = (linuxPackages.callPackage
    ((import (repo + "/module-build.nix")) {
      version = "pnfs-bcachefs";
      dkms = dkmsSrc;
      meta = {
        license = lib.licenses.gpl2Only;
        maintainers = [ ];
      };
    })
    ccache.override).overrideAttrs (o: {
    makeFlags = o.makeFlags ++ [ "BCACHEFS_RUST=${if rust then "1" else "0"}" ];
  });
in
module
