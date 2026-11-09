/*
  Build on aarch64-linux, then run outside the Nix build sandbox:

    nix-build -E '(import ./. { config.allowUnfree = true; }).callPackage ./pkgs/test/steam-arm64/native-fhs-smoke.nix { }'
    env -u STEAM_EXTRA_COMPAT_TOOLS_PATHS -u STEAM_COMPAT_EMULATOR -u STEAM_COMPAT_GRAPHICS_PROVIDER result/bin/steam-native-fhs-smoke

  This uses the exact FHS root of the default Steam package, including its
  default compatibility-tool registration, without starting the Steam UI.
  Evaluation cannot catch foreign /etc files merged through profile closures.
*/
{
  lib,
  stdenv,
  steam,
  buildFHSEnv,
  writeShellScript,
}:

assert stdenv.hostPlatform.isAarch64 && stdenv.hostPlatform.isLinux;

let
  expectedTools = lib.makeSearchPathOutput "steamcompattool" "" steam.compatPackages;
  probe = buildFHSEnv (
    steam.args
    // {
      executableName = "steam-native-fhs-smoke";
      extraInstallCommands = "";
      passthru = { };
      meta.mainProgram = "steam-native-fhs-smoke";
      runScript = writeShellScript "steam-native-fhs-smoke" ''
        set -eu
        test "$(uname -m)" = aarch64
        test "$(getconf PAGESIZE)" = 4096
        test -s /etc/ld.so.conf
        test -f /etc/ld.so.cache
        /lib/ld-linux-aarch64.so.1 --list /usr/bin/true
        /usr/bin/true
        test "''${STEAM_EXTRA_COMPAT_TOOLS_PATHS-}" = ${lib.escapeShellArg expectedTools}
        test -z "''${STEAM_COMPAT_EMULATOR-}"
        test -z "''${STEAM_COMPAT_GRAPHICS_PROVIDER-}"
        printf '%s\n' 'Native default Steam FHS started with compatibility tools registered outside its root filesystem.'
      '';
    }
  );
in
assert probe.fhsenv.drvPath == steam.fhsenv.drvPath;
probe
