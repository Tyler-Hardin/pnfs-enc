#!/usr/bin/env bash
# Build and run a standalone NixOS test from nix/tests/.
#
#   dev/run-nixos-test.sh [--dry-run]                # nix/tests/btrfs.nix
#   TEST=bcachefs.nix dev/run-nixos-test.sh          # nix/tests/bcachefs.nix
#   PROFILE=gce-network-storage ...                  # the link and disk to measure
#   WIP_KERNEL=<bzImage> ...      # boot a kernel built in this tree (kbuild.sh)
#
# PROFILE selects a bed from nix/tests/profiles.nix; the default is `lan`, the
# hourglass the VMs actually have. doc/development.md has what each profile is and
# what the emulation can express.
#
# The kernel is 6.18 LTS (6.18.50), the base the feature and the patch are built
# against; the 7.2 variant went stale and was dropped. nixpkgs comes from the
# flake registry (26.05, 6.18.50) rather than the bcachefs-tools lock (26.11,
# 7.1.1). The tests live in nix/tests/ and are read from there, so this passes an
# impure expression. Extra arguments go to nix build.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
test_file=${TEST:-btrfs.nix}
profile=${PROFILE:-lan}
result_name=${test_file%.nix}
[ "$profile" = lan ] || result_name=$result_name-$profile
wip_kernel=

# WIP_KERNEL: boot the VMs with a bzImage built by kbuild.sh --image instead of
# the one nix builds from the patch.  The QEMU run scripts read
# NIXPKGS_QEMU_KERNEL_<node>, so the kernel goes in as an environment variable on
# the test derivation; it has to be a store path (the sandbox needs it as an
# input, and a plain path under $HOME is not even readable by the build user),
# which is what `nix store add-file` above gives us.  What this does *not*
# replace: the initrd and the module tree are still the nix kernel's, so a
# change to an initrd module, to the config, or to module ABI needs the normal
# patch-based run.  Same-version, same-config kernels are ABI-compatible.
if [ -n "${WIP_KERNEL:-}" ]; then
	if [ ! -f "$WIP_KERNEL" ]; then
		echo "run-nixos-test: WIP_KERNEL=$WIP_KERNEL is not a file" >&2
		exit 1
	fi
	case "$WIP_KERNEL" in
	/nix/store/*) wip_kernel=$WIP_KERNEL ;;
	*) wip_kernel=$(nix store add-file "$WIP_KERNEL") ;;
	esac
	result_name=$result_name-wip
	echo "run-nixos-test: WIP kernel $wip_kernel" >&2
	echo "run-nixos-test:   initrd and modules are still the nix kernel's; the gate is the run without WIP_KERNEL" >&2
	marker=$root/linux/.config.pnfs-test
	if [ -f "$marker" ] && [ "$(cat "$marker")" != "$test_file" ]; then
		echo "run-nixos-test: warning: that kernel was configured for $(cat "$marker"), not $test_file" >&2
	fi
else
	# The test builds its kernel from the *generated* patch, so a kernel edit
	# that has not been through mkpatch.sh is invisible: the run would test the
	# old kernel and pass.  Say so before spending ten minutes finding out.
	# (With WIP_KERNEL the kernel comes from the tree, so the patch does not
	# matter - but the gate would still need it.)
	if [ -d "$root/linux/.git" ] && ! "$here/mkpatch.sh" --check >/dev/null 2>&1; then
		echo "run-nixos-test: warning: linux/ does not match $root/nix/patches/pnfs-layout-6.18.patch" >&2
		echo "run-nixos-test:          the test builds the patch, not the checkout - run mkpatch.sh" >&2
	fi
fi

# An opt-in compiler cache (see ccache.nix): persistent, and visible to the
# sandbox, which is why it is a path outside the workspace.
sandbox_args=()
if [ -n "${PNFS_CCACHE:-}" ]; then
	if [ ! -d "$PNFS_CCACHE" ]; then
		echo "run-nixos-test: PNFS_CCACHE=$PNFS_CCACHE does not exist" >&2
		echo "run-nixos-test:   mkdir -m 777 $PNFS_CCACHE   # the build user has to write it" >&2
		exit 1
	fi
	sandbox_args=(--option extra-sandbox-paths "$PNFS_CCACHE")
fi

# PNFS_RERUN: force the test to actually run again.  A derivation nix has
# already built is a no-op - `nix build` on it prints nothing and exits 0 - so a
# second identical run of a suite (a benchmark repeat, say) would otherwise
# report success without executing anything.  The nonce is an unused environment
# variable on the test derivation: it changes the derivation, so nix runs it.
run_id=
if [ -n "${PNFS_RERUN:-}" ]; then
	run_id=$(date +%s)-$$
fi

expr='
let
  pkgs = import (builtins.getFlake "nixpkgs") { system = "x86_64-linux"; };
  test = import '"$root/nix/tests/$test_file"' {
    inherit pkgs;
    lib = pkgs.lib;
    profile = "'"$profile"'";
  };
  env =
    (if "'"$wip_kernel"'" == "" then { } else builtins.listToAttrs (map (n: {
      name = "NIXPKGS_QEMU_KERNEL_" + n;
      value = builtins.storePath "'"$wip_kernel"'";
    }) (builtins.attrNames test.nodes)))
    // (if "'"$run_id"'" == "" then { } else { PNFS_RUN_ID = "'"$run_id"'"; });
in
if env == { } then test else test.overrideTestDerivation (_: env)
'

exec nix build --impure --expr "$expr" -L -o "$here/result-$result_name" \
	${sandbox_args[@]+"${sandbox_args[@]}"} "$@"
