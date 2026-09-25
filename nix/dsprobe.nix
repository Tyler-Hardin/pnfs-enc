# dsprobe: ask the data service whether it is answering.
#
# The service is an RPC program that is deliberately not registered with
# rpcbind, so rpcinfo cannot reach it and there is nothing to ping. This sends
# the NULL procedure and reports the answer, which is what tells an operator
# "the process is up and reachable" apart from "the kernel is up".
#
#   dsprobe <host> [port]      # default port 2050
{ lib, stdenv, libtirpc }:

stdenv.mkDerivation {
  pname = "dsprobe";
  version = "1";
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o dsprobe ${./dsprobe.c} \
      -I${libtirpc.dev}/include/tirpc \
      -L${libtirpc}/lib -Wl,-rpath,${libtirpc}/lib -ltirpc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 dsprobe $out/bin/dsprobe
    runHook postInstall
  '';

  meta = {
    description = "Ask a pNFS encoded-extent data service whether it is answering";
    mainProgram = "dsprobe";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
