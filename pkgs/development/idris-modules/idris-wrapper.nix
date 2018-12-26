{ stdenv, lib, symlinkJoin, makeWrapper, idris-no-deps, gcc, gmp }:

symlinkJoin {
  inherit (idris-no-deps) name src meta;
  paths = [ idris-no-deps ];
  buildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/idris \
      --run 'export IDRIS_CC=''${IDRIS_CC:-/nix/store/ikk8899vd9yigrw06rffxqx3pdj9n96l-clang-wrapper-5.0.2/bin/clang}' \
      --suffix LIBRARY_PATH : ${lib.makeLibraryPath [ gmp ]}
  '';
}
