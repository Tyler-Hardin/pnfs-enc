#!/usr/bin/env bash
# Regenerate a kernel patch from a modified ("spike") tree.
#
#   ./mkpatch.sh                       # 6.18 LTS: the live tree (git diff)
#   ./mkpatch.sh --check               # exit 1 if the patch is out of date
#   SPIKE=<modified 7.2.x tree> PRISTINE=/home/tyler/.cache/pnfs-7.2.3/linux-7.2.3 \
#   OUT=./nix/patches/pnfs-layout-7.2.patch SPIKE=<7.2 tree> ./mkpatch.sh  # other kernels
#
# The spike tree is a pristine kernel extraction with our changes; the patch is
# a unified diff over just the files we touch, so it applies with `patch -p1` to
# a pristine tree of the same version (and is how the NixOS test gets a kernel
# with the layout type in it).
#
# The file list below is explicit on purpose: a new file has to be added here,
# which is also the reminder that the patch's coverage is a decision, not an
# accident. The pristine tree is extracted once and cached.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
spike=${SPIKE:-$root/linux}
out=${OUT:-$root/nix/patches/pnfs-layout-6.18.patch}
pristine=${PRISTINE:-/home/tyler/.cache/pnfs-6.18.50/linux-6.18.50}
tarball=${TARBALL:-/nix/store/izkbpb5ssbss6bl5s40fbzsahnlf3b7j-linux-6.18.50.tar.xz}

# --check: generate as usual, but compare against the patch on disk instead of
# replacing it, so a caller can tell whether the test would build the checkout's
# current state.  Same generation path, so it cannot disagree with a real run.
check_against=
if [ "${1:-}" = "--check" ]; then
	check_against=$out
	out=$(mktemp)
fi

files=(
	include/linux/nfs4.h
	include/linux/exportfs.h
	include/linux/encoded_extent.h
	include/linux/encoded_extent_ds.h
	fs/Kconfig
	fs/Makefile
	fs/encoded_extent.c
	fs/nfsd/pnfs.h
	fs/nfsd/nfs4layouts.c
	fs/nfsd/Makefile
	fs/nfsd/Kconfig
	fs/nfsd/encoded_ds.c
	fs/nfsd/bcachefs_layout.c
	fs/nfs/Makefile
	fs/nfs/Kconfig
	fs/nfs/pnfs.h
	fs/nfs/bcachefs_layout.c
	fs/nfs/bcachefs_ds.c
	fs/nfs/bcachefs_ds.h
	fs/btrfs/ioctl.c
	fs/btrfs/export.c
	fs/btrfs/btrfs_inode.h
	fs/btrfs/compression.h
	fs/btrfs/zstd.c
	fs/btrfs/super.c
	fs/btrfs/Makefile
	fs/btrfs/encoded_extent.c
)

if [ ! -d "$pristine" ]; then
	mkdir -p "$(dirname "$pristine")"
	tar -xf "$tarball" -C "$(dirname "$pristine")"
fi

for f in "${files[@]}"; do
	if [ ! -f "$spike/$f" ]; then
		echo "mkpatch: $f listed but missing from the spike tree" >&2
		exit 1
	fi
done

# The spike tree is a git checkout whose first commit is the pristine sources,
# tagged "baseline"; the patch is the tree against that tag, so the tree's
# history is the source of truth and build artifacts cannot leak in. The file
# list still bounds it, and is still the decision about what the patch covers.
#
# A file that is new has to be in the index (git add) or it will not appear.
if git -C "$spike" rev-parse --verify --quiet "${baseline:-baseline}" >/dev/null; then
	git -C "$spike" diff --no-abbrev "${baseline:-baseline}" -- \
		"${files[@]}" > "$out"
else
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT

	for f in "${files[@]}"; do
		mkdir -p "$work/a/$(dirname "$f")" "$work/b/$(dirname "$f")"
		if [ -f "$pristine/$f" ]; then
			cp "$pristine/$f" "$work/a/$f"
		fi
		cp "$spike/$f" "$work/b/$f"
	done

	( cd "$work" && diff -ruN a b ) > "$out" || true
fi

if [ -n "$check_against" ]; then
	if [ -f "$check_against" ] && cmp -s "$out" "$check_against"; then
		rm -f "$out"
		exit 0
	fi
	echo "mkpatch: $check_against does not match the checkout" >&2
	rm -f "$out"
	exit 1
fi

echo "wrote $out ($(wc -l < "$out") lines, ${#files[@]} files)"
