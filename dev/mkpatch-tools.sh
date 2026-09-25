#!/usr/bin/env bash
# Regenerate nix/patches/bcachefs-tools.patch, the backend half of the product:
# the commits in ../bcachefs-tools on top of the upstream tag the flake pins.
#
#   dev/mkpatch-tools.sh            # write the patch
#   dev/mkpatch-tools.sh --check    # exit 1 if the patch on disk is out of date
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out=$root/nix/patches/bcachefs-tools.patch
# The base is the upstream revision the flake pins.  Find it from the
# upstream branch, not from this branch's depth, so regenerating still
# works after the series is squashed.
base=${BASE:-$(git -C "$root/bcachefs-tools" describe --tags --abbrev=0 --match 'v*' origin/master 2>/dev/null || echo v1.39.6)}

tmp=$(mktemp)
git -C "$root/bcachefs-tools" diff "$base" > "$tmp"
if [ "${1:-}" = --check ]; then
	if diff -q "$tmp" "$out" >/dev/null; then
		rm -f "$tmp"; echo "mkpatch-tools: $out is current"
	else
		rm -f "$tmp"; echo "mkpatch-tools: $out is out of date (base $base)" >&2; exit 1
	fi
else
	mv "$tmp" "$out"
	echo "wrote $out ($(wc -l < "$out") lines over $(grep -c '^diff --git' "$out") files, base $base)"
fi
