# What both halves need: the patched kernel - the layout driver is in fs/nfs
# and the data service in fs/nfsd, so a server and a client want the same one -
# and the codec provider module built beside it. The codec is a *provider* for
# both: the server calls into it to read and write the encoded units, and a
# client loads it on demand when a layout names its codec (and needs nothing
# else from bcachefs to mount one).
#
# Both modules import this, so on a host that is both a server and a client it
# is evaluated twice. The module system keeps one module per `key` (that is how
# `imports = [ ./file.nix ]` twice is one module rather than two), so the `key`
# below is what makes the second import this same module instead of a second
# definition of the options: `boot.kernelPackages` has no merge function, and
# two definitions - even two identical `mkDefault` ones - are an error.
{ bcachefsTools }:
{ lib, pkgs, ... }:

let
  pnfs = import ../kernel.nix { inherit pkgs; };

  bcachefsModule = import ../bcachefs-module.nix {
    inherit pkgs;
    kernel = pnfs.kernel;
    src = pkgs.applyPatches {
      name = "bcachefs-tools-encoded-extent";
      src = bcachefsTools.src;
      patches = [ bcachefsTools.patch ];
    };
  };
in
{
  key = "pnfs/backend";

  # mkDefault so a host with its own kernel choice can override.
  boot.kernelPackages = lib.mkDefault pnfs.linuxPackages;
  boot.extraModulePackages = [ bcachefsModule ];

  # dsprobe answers "is the data service up?" - the one question nfsd's own
  # tools cannot ask, since the service is not registered with rpcbind.
  environment.systemPackages = [ pnfs.dsprobe ];
}
