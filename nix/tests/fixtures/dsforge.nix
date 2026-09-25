{ pkgs }:

pkgs.stdenv.mkDerivation {
  name = "dsforge";
  dontUnpack = true;
  buildPhase = ''
    $CC -O2 -Wall -o dsforge ${./dsforge.c} \
      -I${pkgs.libtirpc.dev}/include/tirpc \
      -L${pkgs.libtirpc}/lib -Wl,-rpath,${pkgs.libtirpc}/lib -ltirpc
  '';
  installPhase = "install -Dm755 dsforge $out/bin/dsforge";
}
