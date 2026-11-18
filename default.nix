let
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/177d0540942fb205af6993b1d5fa0b57799e09f8.tar.gz";
    sha256 = "016lz50fim2ln0s6rcql3an3zs2ljcm756cwcnq0694skaxprw2a";
  }) {
    # The upstream resource bundle includes MiSans under a restrictive license.
    config.allowUnfreePredicate = pkg: (pkg.pname or "") == "rhine-music-database";
  };
in
pkgs.callPackage ./package.nix { }
