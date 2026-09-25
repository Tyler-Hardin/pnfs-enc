#!/usr/bin/env bash
# Incremental in-tree kernel build: the fast compile loop for kernel-side edits.
#
#   dev/kbuild.sh                      # one object (default: the DS)
#   dev/kbuild.sh fs/nfs/bcachefs_ds.o
#   dev/kbuild.sh --test-config        # adopt the test kernel's .config
#   dev/kbuild.sh --image              # incremental bzImage
#
# `--image`, together with WIP_KERNEL in run-nixos-test.sh, is the edit/boot
# loop: the kernel is built here, by `make`, so the object files stay in the
# tree and only a changed file and the link steps are redone; the NixOS test
# then boots *that* bzImage (see kloop.sh).  The first --image is a full build
# (about the same work as the nix kernel build); after that an edit is seconds
# to a minute, because `make` keeps everything.
#
# `--test-config` is what makes the hand-built kernel usable by the test: it
# takes the .config the test's nix-built kernel uses, so version, module ABI and
# the built-in/module split all match the initrd and module tree the test boots
# with.  Without it, `make` would invent a default config that nothing matches.
#
# Build artifacts land in linux/ and are covered by the kernel's own
# .gitignore, so the checkout stays clean; mkpatch.sh only diffs a fixed file
# list, so they cannot leak into the generated patch either.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
src=${KSRC:-$root/linux}
test_file=${TEST:-btrfs.nix}

mode=build
case "${1:-}" in
--test-config)
	mode=test-config
	shift
	;;
--image)
	target=bzImage
	shift
	;;
*)
	target=${*:-fs/nfsd/encoded_ds.o}
	;;
esac

if [ "$mode" = test-config ]; then
	# The test's kernel, and so its config: any node has the same one, and the
	# node names are the driver's (server/client), not the test's file name.
	expr='
let
  pkgs = import (builtins.getFlake "nixpkgs") { system = "x86_64-linux"; };
  test = import '"$root/nix/tests/$test_file"' { inherit pkgs; lib = pkgs.lib; };
  nodes = builtins.attrNames test.nodes;
in test.nodes.${builtins.head nodes}.boot.kernelPackages.kernel.configfile
'
	# Realise it: the config is not a GC root, so the path an evaluation hands
	# back may have been collected since - and `install` of a collected path
	# fails with nothing more useful than "No such file or directory".
	config=$(nix build --impure --no-link --print-out-paths --expr "$expr")
	# The release string has to come out exactly as the nix kernel's, because the
	# initrd and the module tree the test mounts are still nix's, under
	# lib/modules/$(uname -r).  nix builds from a tarball, so its release is a
	# plain "6.18.50"; this is a git checkout, and the config has
	# CONFIG_LOCALVERSION_AUTO=y, so setlocalversion would append
	# "-00010-g096fb3e8c8" - and then nothing loads and the initrd hangs for the
	# 300 s boot timeout looking for the root device.  Disable it.
	staged=$(mktemp)
	sed 's/^CONFIG_LOCALVERSION_AUTO=y$/# CONFIG_LOCALVERSION_AUTO is not set/' \
		"$config" > "$staged"
	if [ -f "$src/.config" ] && cmp -s "$staged" "$src/.config"; then
		echo "kbuild: $src/.config already matches the test kernel's"
	else
		install -m 644 "$staged" "$src/.config"
		echo "kbuild: $src/.config <- $config (LOCALVERSION_AUTO off: see above)"
	fi
	rm -f "$staged"
	# Which test's kernel this tree is configured for: the two tests differ (the
	# btrfs test builds btrfs in, the bcachefs test builds it as a module), and a
	# kernel built for one is the wrong kernel for the other.
	printf '%s\n' "$test_file" > "$src/.config.pnfs-test"
	target=olddefconfig
fi

# A kernel built from a config nothing else uses would not match the initrd and
# module tree the test boots with, so --image refuses to invent one.
if [ "$mode" != test-config ] && [ "${target}" = bzImage ] && [ ! -f "$src/.config" ]; then
	echo "kbuild: $src/.config is missing - run '$0 --test-config' first" >&2
	exit 1
fi

# RUST_LIB_SRC: the Rust support in the kernel is an *availability* check, and
# the bcachefs module is Rust, so the kernel has to export the core crate.
# nixpkgs points that check at the Rust library sources; without it,
# scripts/rust_is_available.sh says no and olddefconfig quietly drops
# CONFIG_RUST - and then the nix-built bcachefs module fails to load with
# "Unknown symbol _RNvNtCsjP4D606FrJC_..." (note: no apostrophes below - this
# expression lives in a single-quoted shell string).
exec nix develop --impure --expr '
let
  pkgs = import (builtins.getFlake "nixpkgs") { system = "x86_64-linux"; };
  k = pkgs.linuxPackages.kernel;
in
pkgs.mkShell {
  nativeBuildInputs = k.moduleBuildDependencies
    ++ (with pkgs; [ bison flex openssl elfutils zlib ]);
  RUST_LIB_SRC = "${pkgs.rustPlatform.rustLibSrc}";
}
' --command bash -c "
set -e
cd '$src'
# Empty but *set*: setlocalversion appends a '+' to a release built from a git
# tree that is not at a signed/annotated tag, unless LOCALVERSION is set - and
# the nix kernel's release (from a tarball) has no suffix at all.  Together with
# LOCALVERSION_AUTO off in the config, this makes \$(make kernelrelease) come out
# as plain '6.18.50', which is what the module tree is named.
export LOCALVERSION=""
make olddefconfig
make -j\$(nproc) prepare
make -j\$(nproc) $target
"
