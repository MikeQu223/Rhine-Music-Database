let
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/177d0540942fb205af6993b1d5fa0b57799e09f8.tar.gz";
    sha256 = "016lz50fim2ln0s6rcql3an3zs2ljcm756cwcnq0694skaxprw2a";
  }) { };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
    python3
    nodejs_26
    git
    qt6.wrapQtAppsHook
  ];

  buildInputs = with pkgs; [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtshadertools
    qt6.qtmultimedia
    qt6.qtwayland
    qt6.qtsvg
    qt6.qtimageformats
    vulkan-headers
    vulkan-loader
    glslang
  ];

  # Development shells do not run the package fixup phase.
  shellHook = ''
    export QT_PLUGIN_PATH="${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}:${pkgs.qt6.qtwayland}/${pkgs.qt6.qtbase.qtPluginPrefix}:${pkgs.qt6.qtsvg}/${pkgs.qt6.qtbase.qtPluginPrefix}:${pkgs.qt6.qtimageformats}/${pkgs.qt6.qtbase.qtPluginPrefix}''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    export QML2_IMPORT_PATH="${pkgs.qt6.qtdeclarative}/${pkgs.qt6.qtbase.qtQmlPrefix}:${pkgs.qt6.qtmultimedia}/${pkgs.qt6.qtbase.qtQmlPrefix}''${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
  '';
}
