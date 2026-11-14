# Native Nix build

From this repository directory:

```sh
nix-build --cores 6
./result/bin/RhineMusicDatabase
```

The build uses the local source tree and pins nixpkgs to
`177d0540942fb205af6993b1d5fa0b57799e09f8` (Qt 6.12.0, Node 26).
It does not change the system configuration. `nix-shell` provides an interactive
development environment, but is not required for `nix-build`.

If fetching nixpkgs requires the local proxy:

```sh
https_proxy=http://127.0.0.1:20170 http_proxy=http://127.0.0.1:20170 nix-build --cores 6
```

Nix daemon downloads use the daemon's network configuration. The proxy variables
above do not change that configuration.

## Scope

This is an initial x86_64-linux core package. It includes the desktop application,
playback helper, generated scene resources, Node bridge, local music support,
and the built-in Siren provider. Third-party music providers are not preinstalled.
FidelityFX/FSR3/frame generation is disabled; no Git submodules are required for
this configuration. This does not disable the application's ordinary Vulkan and
OpenGL rendering paths.

Both npm lockfiles are fetched with fixed hashes, then installed offline inside
the Nix build. The package uses Nix Qt and FFmpeg libraries rather than producing
an AppImage. Node is linked from the Nix store into the bridge resource directory.

The build runs upstream's core offline CTest selection, the packaged-core layout
check, and local lyrics IPC checks. To repeat the installed application's self-test:

```sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./result/bin/RhineMusicDatabase --self-test
```

These checks do not establish that account login, external provider plugins, or
all audio devices work. Test those interactively before publishing a package.

For display troubleshooting, upstream supports:

```sh
RHINE_QPA_PLATFORM=xcb RHINE_GRAPHICS=opengl ./result/bin/RhineMusicDatabase
```

## Before a nixpkgs submission

`package.nix` is a local working recipe, not a ready-to-submit nixpkgs expression.
Replace its local source with a fixed upstream revision and source hash, adapt
the npm source inputs accordingly, and add a maintainer and accurate version.

The upstream source license is MIT, but the resource bundle also includes MiSans
under a restrictive license. `default.nix` allows this specific unfree package;
it does not enable unfree packages globally. The upstream NOTICE describes
converted fonts and asks distributors to check artwork/model/font permissions.
Clarify the converted fonts' authorization and the other assets' redistribution
terms with upstream before publishing binaries or submitting to nixpkgs.

Useful upstream improvements would be a resource preparation mode without
bundled Node, CMake installation of prepared resources, and a configurable Node
runtime path. The local recipe currently supplies those paths without changing
the application's source.
