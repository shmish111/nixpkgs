{ stdenv, lib, symlinkJoin, makeWrapper, idris-no-deps, gcc, gmp }:

symlinkJoin {
  inherit (idris-no-deps) name src meta;
  paths = [ idris-no-deps ];
  buildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/idris \
      --run 'export IDRIS_CC=''${IDRIS_CC:-${stdenv.cc}/bin/cc} && export NIX_CPATH_LINK=''${NIX_CPATH_LINK:-${lib.makeLibraryPath [ gmp ]}}'
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ gmp ]}
  '';
}
