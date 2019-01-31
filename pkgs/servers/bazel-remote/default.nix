{ stdenv, fetchFromGitHub, buildBazelPackage, cacert, git, go }:

buildBazelPackage rec {
  name = "bazel-remote";

  src = fetchFromGitHub {
    owner = "buchgr";
    repo = "bazel-remote";
    rev = "57a18163783d3d0cb199ad93bcc788c864ec4140";
    sha256 = "18s977715sc44sgnf0rn48jmi5d7saijnh7xfx7mg5r70llvppk6";
  };
  patches = [ ./go-sdk.patch ];

  buildInputs = [
      go
  ];
  shellHook = ''
      export GOROOT="$(go env GOROOT)"
  '';

  bazelTarget = ":bazel-remote";
  nativeBuildInputs = [ git ];

  fetchAttrs = {
    preBuild = ''
      patchShebangs .
      # tell rules_go to invoke GIT with custom CAINFO path
      export GIT_SSL_CAINFO="${cacert}/etc/ssl/certs/ca-bundle.crt"
    '';

    preInstall = ''
      # Remove all built in external workspaces, Bazel will recreate them when building
      rm -rf $bazelOut/external/{bazel_tools,\@bazel_tools.marker,local_*,\@local_*}
      '';
    sha256 = "1nahz55r4f43qspq7r1nl2ip8vs4x2lq3p0qhwrnh0dm3118g0hw";
  };

  buildAttrs = {
    preBuild = ''
      patchShebangs .
    '';

    installPhase = ''
      install -Dm755 bazel-bin/*_pure_stripped/bazel-remote $out/bin/bazel-remote
    '';
  };

  meta = with stdenv.lib; {
    homepage = https://github.com/buchgr/bazel-remote;
    description = "A remote HTTP/1.1 cache for Bazel https://bazel.build";
    license = licenses.asl20;
    maintainers = [ maintainers.shmish111 ];
    platforms = platforms.all;
  };
}
