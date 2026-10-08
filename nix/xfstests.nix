# xfstests 2023.05.14 does not build with a current toolchain, and neither
# problem is a real one.
#
# gcc-15 defaults to C23, where an empty parameter list means (void) rather
# than "unspecified" - so the suite's own old-style definitions of strtok()
# and srand48() conflict with libc's declarations and are hard errors. Building
# it as gnu17 is what it was written for.
#
# And its configure decided libc had neither function, so it compiled
# replacements it did not need, which is what those definitions were. Telling
# it the truth removes them.
#
# -Wno-error is the blunt part: it downgrades the warnings a 2023 tree throws
# at a 2026 compiler so the real errors are still errors. It is what every
# nixpkgs fix for an old third-party suite looks like.
#
# Built and used for fsx (lib/xfstests/ltp/fsx), which is the reason to have
# it: random reads, writes, overwrites and truncates with every read verified,
# and -f drops the cache after each operation so the verification reads come
# from the filesystem rather than from the writer's page cache.
{ pkgs }:
pkgs.xfstests.overrideAttrs (o: {
  NIX_CFLAGS_COMPILE = "-Wno-error -std=gnu17";
  configureFlags = (o.configureFlags or []) ++ [
    "ac_cv_func_strtok=yes"
    "ac_cv_func_srand48=yes"
  ];
})
