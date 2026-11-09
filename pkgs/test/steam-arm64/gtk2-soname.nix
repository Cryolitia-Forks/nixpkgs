/*
  Inspect the actual GTK2 output selected by the ARM64 Steam FHS environment.
  The check runs on the build machine and does not execute ARM64 code. Its
  dependency must nevertheless be built by an ARM64 builder or substituted.

    nix-build -E '(import ./. { }).callPackage ./pkgs/test/steam-arm64/gtk2-soname.nix { }'
*/
{
  lib,
  pkgs,
  runCommand,
  binutils,
  gnugrep,
}:

let
  armPkgs = import pkgs.path {
    system = "aarch64-linux";
    config.allowUnfree = true;
  };
  gtk2 =
    lib.findFirst (package: lib.elem "gtk+-2.0" (package.meta.pkgConfigModules or [ ]))
      (throw "The native ARM64 Steam FHS environment does not provide GTK2")
      (armPkgs.steam.args.multiPkgs armPkgs);
in
runCommand "steam-arm64-gtk2-soname"
  {
    nativeBuildInputs = [
      binutils
      gnugrep
    ];
  }
  ''
    library=${lib.escapeShellArg "${lib.getLib gtk2}/lib/libgtk-x11-2.0.so.0"}
    test -f "$library"
    readelf --file-header "$library" | grep -Eq 'Machine:[[:space:]]+AArch64'
    readelf --dynamic "$library" | grep -Eq '\(SONAME\).*\[libgtk-x11-2\.0\.so\.0\]'
    touch "$out"
  ''
