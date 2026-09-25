# The same compile, with the Rust half on: this is the module a server or a
# client actually loads, so it is the check that matters of the two.
#
#   nix build .#checks.x86_64-linux.bcachefs-module-rust
# @src is the *patched* backend tree, `.#packages.<system>.bcachefs-tools-src`:
# the module build consumes a source tree, not a patch, and applying the patch
# here as well is what a double application looks like.
{ pkgs, src }:

(import ../bcachefs-module.nix {
  inherit pkgs src;
  kernel = (import ../kernel.nix { inherit pkgs; }).kernel;
  rust = true;
})
