# Optional shared compiler cache for the kernel and the bcachefs module.
#
# The tests are hermetic without it: with PNFS_CCACHE unset - the default, and
# what the committed gate runs - the kernel is built from the patch exactly as
# before.  With it set, the same sources are compiled by the same compiler, but
# a translation unit that has not changed comes out of the cache instead of
# being recompiled, which is the difference between a full rebuild and a
# one-file change on every kernel edit.
#
# `builtins.getEnv` is why this is read impurely; the tests are already
# evaluated that way (the runner passes an impure expression, because the test
# files are not flake outputs).  The directory has to be *both* persistent and
# visible to the sandbox: run-nixos-test.sh adds it to extra-sandbox-paths, and
# the build user must be able to write it, so it cannot live under a mode-700
# $HOME.  On this machine:
#
#   mkdir -m 777 /var/tmp/pnfs-ccache
#   PNFS_CCACHE=/var/tmp/pnfs-ccache dev/run-nixos-test.sh
#
# The settings go through ccacheStdenv's `extraConfig` - a snippet sourced by
# the compiler wrapper - rather than through each derivation's environment, and
# that is not a style choice: the kernel's *config* step runs in a derivation of
# its own, where Kconfig probes the assembler, and a ccache in there with no
# usable cache directory fails that probe with "unknown assembler invoked" /
# "this assembler is not supported" (a baffling way to be told about a cache
# directory).  Baking the settings into the wrapper covers every compile,
# including that one.
#
# CCACHE_IGNOREOPTIONS is the other thing that makes this work at all: nixpkgs'
# cc-wrapper appends a per-derivation `-frandom-seed=<random>`, so without
# ignoring it every compile in a new derivation is a miss even when nothing
# changed (verified: two derivations compiling the same file, the only
# difference in the command line being the seed).  The seed only affects how the
# compiler names local statics, so a cached object reused under a new seed is
# the same machine code; what it costs is bit-identical reproducibility against
# a from-scratch build, which is exactly what the uncached gate is for.
#
# CCACHE_SLOPPINESS is the third piece, and it is worth the words because its
# failure mode is silent: ccache hashes the *values* of __DATE__, __TIME__ and
# __TIMESTAMP__ unless told not to, and the kernel reaches them through
# generated headers, so ~26,657 of a build's ~80,000 compiles missed on
# every single build - even a rebuild of the identical derivation (measured; the
# misses drop to 11 with this set).  What it costs: an object may keep the build
# time of the build that produced it, which is exactly the kind of thing nix's
# reproducibility is for; the gate does not use the cache, and KBUILD_BUILD_*
# (what the kernel's own version string comes from) is set deterministically by
# nixpkgs either way.  It cannot hide a source change: only the time macros are
# ignored, not the source.
{ pkgs, lib }:

let
  dir = builtins.getEnv "PNFS_CCACHE";
  enabled = dir != "";

  stdenv = pkgs.ccacheStdenv.override {
    stdenv = pkgs.stdenv;
    extraConfig = ''
      export CCACHE_DIR=${dir}
      export CCACHE_UMASK=000
      export CCACHE_MAXSIZE=50G
      export CCACHE_COMPRESS=1
      export CCACHE_IGNOREOPTIONS="-frandom-seed=*"
      export CCACHE_SLOPPINESS=time_macros
    '';
  };
in
{
  inherit enabled dir;

  # Splat into a package's `.override`: buildLinux takes stdenv as an argument,
  # so this changes the derivation and every compile it runs goes through
  # ccache.  Empty when disabled, so the derivation (and the gate) is unchanged.
  override = lib.optionalAttrs enabled { inherit stdenv; };
}
