#!/usr/bin/env bash
# The edit/boot loop: rebuild the kernel here, boot it in the NixOS test.
#
#   dev/kloop.sh [run-nixos-test.sh arguments...]
#
# It is the two commands it replaces, so the pieces stay visible:
#
#   dev/kbuild.sh --image
#   WIP_KERNEL=linux/arch/x86/boot/bzImage dev/run-nixos-test.sh
#
# The point is that `make` keeps the object files in linux/, so a kernel edit
# costs one recompile and the link steps, and the test boots that bzImage
# through QEMU's NIXPKGS_QEMU_KERNEL_<node> hook.  The first run builds the
# whole kernel (about the work the nix build does) after adopting the test
# kernel's config, which is required: version, module ABI and the built-in/module
# split have to match the initrd and module tree the test supplies from nix.
#
# What this loop does not cover, and the gate does: changes to the kernel
# *config*, to a module the initrd or the system closure needs, or anywhere the
# module ABI matters - those need `run-nixos-test.sh` without WIP_KERNEL, which
# builds the kernel from the generated patch.  If the config in the test drifts
# (a new option in the test files), re-run `kbuild.sh --test-config`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
image=$root/linux/arch/x86/boot/bzImage
test_file=${TEST:-btrfs.nix}
marker=$root/linux/.config.pnfs-test

if [ ! -f "$root/linux/.config" ]; then
	echo "kloop: no linux/.config yet - adopting the test kernel's"
	"$here/kbuild.sh" --test-config
elif [ -f "$marker" ] && [ "$(cat "$marker")" != "$test_file" ]; then
	# The two suites have different kernels (the btrfs test builds btrfs in, the
	# bcachefs test builds it as a module); building for one and testing the
	# other is wrong in a way that still boots, so adopt the right config and
	# pay for the rebuild.
	echo "kloop: linux/.config is for $(cat "$marker"), not $test_file - re-adopting (full rebuild)"
	"$here/kbuild.sh" --test-config
fi

"$here/kbuild.sh" --image

WIP_KERNEL=${WIP_KERNEL:-$image} exec "$here/run-nixos-test.sh" "$@"
