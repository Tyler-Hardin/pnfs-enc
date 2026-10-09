# The kernel this feature is: 6.18 LTS with the encoded-extent layout patch and
# the options it needs, server and client both on.
#
# The patch is generated against 6.18.50 (`dev/mkpatch.sh`), and it applies to
# the 6.18 series, which is what the check below allows. A kernel minor or major
# bump needs the patch regenerated and the check raised with it - that is the
# one piece of version coupling this feature has.
# kmsan: build this kernel with Clang and KMSAN, to find reads of
# uninitialised memory in the code under test. It is not a boot option and not
# a kernel patch - NixOS' kernels are GCC builds, and KMSAN instrumentation
# exists only in Clang - so this is a from-source rebuild with a different
# compiler. It roughly doubles memory use and slows the machine a lot, and it
# is mutually exclusive with KASAN, KCSAN and PREEMPT_RT.
{ pkgs, kmsan ? false }:

let
  inherit (pkgs) lib;
  inherit (lib) kernel;

  kmsanConfig = lib.optionalAttrs kmsan {
    KMSAN = yes;
    KMSAN_CHECK_PARAM_RETVAL = yes;
    DEBUG_KERNEL = yes;
    # Kconfig gives KMSAN "depends on !KASAN && !KCSAN && !PREEMPT_RT".
    KASAN = lib.mkForce no;
    KCSAN = lib.mkForce no;
    PREEMPT_RT = lib.mkForce no;
  };

  patched = pkgs.linuxPackages.kernel.override ({
    kernelPatches = [
      {
        name = "pnfs-bcachefs-layout";
        patch = ./patches/pnfs-layout-6.18.patch;
      }
    ];

    # mkForce: the kernel config here is a module system, and the common config
    # already sets some of these (NFS_FS to a module, for one); redefining one
    # is a conflict, not an override.
    structuredExtraConfig = with lib.kernel; {
      # Client: NFSv4.1 with the encoded-extent layout driver.
      NFS_FS = lib.mkForce yes;
      NFS_V4 = lib.mkForce yes;
      NFS_V4_1 = lib.mkForce yes;
      PNFS_BCACHEFS_LAYOUT = lib.mkForce yes;

      # Server: nfsd with the same layout type and the data service it needs.
      NFSD = lib.mkForce yes;
      NFSD_V4 = lib.mkForce yes;
      NFSD_PNFS = lib.mkForce yes;
      NFSD_ENCODED_DS = lib.mkForce yes;
      NFSD_BCACHEFS_LAYOUT = lib.mkForce yes;

      # The other pNFS server layout types are off, and that is deliberate: a
      # client offered two layout types for one export may not choose ours, and
      # a bcachefs filesystem on a real device can look like a candidate for the
      # block and SCSI types. If you export pNFS filesystems that need them,
      # build a kernel without this block and pass the layout type explicitly.
      NFSD_BLOCKLAYOUT = lib.mkForce no;
      NFSD_SCSILAYOUT = lib.mkForce no;
      NFSD_FLEXFILELAYOUT = lib.mkForce no;
    } // kmsanConfig;
  } // lib.optionalAttrs kmsan {
    # nixpkgs' shared kernel config still lists options only GCC accepts, and
    # KMSAN also turns off several hand-written assembly crypto drivers; the
    # config stage fails on those rather than ignoring them.
    stdenv = pkgs.llvmPackages.stdenv;
    ignoreConfigErrors = true;
    # KMSAN needs the kernel actually compiled by Clang. Setting the stdenv is
    # not always enough for nixpkgs to notice, so say it the way a Clang kernel
    # build does and let it be detected from there.
    extraMakeFlags = [
      "LLVM=1"
      "CC=${pkgs.llvmPackages.clang}/bin/clang"
      "LD=${pkgs.llvmPackages.lld}/bin/ld.lld"
    ];
  });
in
{
  kernel = patched;
  linuxPackages = pkgs.linuxPackagesFor patched;
  dsprobe = pkgs.callPackage ./dsprobe.nix { };

  # Where the patch and the kernel package come from, for the modules' messages.
  version = patched.version;
} //
lib.throwIfNot (lib.hasPrefix "6.18." patched.version)
  "pnfs-encoded-extent: the kernel patch is generated for 6.18 (currently ${patched.version}). Regenerate it with dev/mkpatch.sh, or pin nixpkgs to a 6.18 release."
  { }
