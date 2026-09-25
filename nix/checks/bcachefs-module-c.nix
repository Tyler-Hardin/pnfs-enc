# Compile the bcachefs module's C half against the patched kernel: the check
# that the encoded-extent backend still builds where it has to, without paying
# for bindgen and Rust.
#
#   nix build .#checks.x86_64-linux.bcachefs-module-c
# @src is the *patched* backend tree, `.#packages.<system>.bcachefs-tools-src`:
# the module build consumes a source tree, not a patch, and applying the patch
# here as well is what a double application looks like.
{ pkgs, src }:

(import ../bcachefs-module.nix {
  inherit pkgs src;
  kernel = (import ../kernel.nix { inherit pkgs; }).kernel;
  rust = false;
})
