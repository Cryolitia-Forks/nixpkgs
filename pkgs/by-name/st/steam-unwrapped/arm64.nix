{
  lib,
  stdenvNoCC,
  fetchurl,
  runCommand,
  libarchive,
  bash,
  coreutils,
  gnugrep,
  gnused,
  util-linuxMinimal,
  replaceVars,
  callPackage,
  legacySteam,
}:

let
  sources = lib.importJSON ./arm64-sources.json;
  archives = lib.mapAttrs (
    _: component:
    fetchurl {
      url = "https://client-update.steamstatic.com/${component.file}";
      inherit (component) sha256;
    }
  ) sources.components;

  bootstrap =
    runCommand "steam-arm64-bootstrap-${sources.version}"
      {
        nativeBuildInputs = [ libarchive ];
      }
      ''
        mkdir -p "$out"

        # Despite its name and IsBootstrapperPackage flag, this archive contains
        # the x86 bootstrap executable. Only its shared launcher/data are useful.
        bsdtar -xf ${archives.steam_linuxarm64} -C "$out" \
          steam.sh steam_msg.sh steam_subscriber_agreement.txt

        # The ARM64 executable needs Valve's matching SDL and FFmpeg libraries
        # even before it has downloaded the rest of the client.
        ${lib.concatMapStringsSep "\n" (component: "bsdtar -xf ${archives.${component}} -C \"$out\"") [
          "bins_linuxarm64_linuxarm64"
          "codecs_linuxarm64_linuxarm64"
          "sdl3_linuxarm64_linuxarm64"
          "public_all"
          "strings_en_all"
          "bins_sdk_linuxarm64"
          "bins_sdk_linuxarm64_linuxarm64"
        ]}

        test -f "$out/steamrtarm64/steam"
        test -e "$out/steamrtarm64/libSDL3.so.0"
        test -e "$out/steamrtarm64/libavcodec.so.62"
        test -f "$out/public/steambootstrapper_english.txt"
        test -f "$out/linux32/steamclient.so"
        test -f "$out/linux64/steamclient.so"
        test -f "$out/linuxarm64/steamclient.so"
      '';

  launcher = replaceVars ./steam-arm64.sh {
    inherit
      bootstrap
      bash
      coreutils
      gnugrep
      gnused
      ;
    utilLinux = util-linuxMinimal;
  };
in
stdenvNoCC.mkDerivation {
  pname = "steam-unwrapped";
  version = sources.version;

  # Keep Steam's desktop integration and device rules from the official
  # launcher package, without installing its x86 executable or bootstrap.
  inherit (legacySteam) src;
  dontBuild = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    make install-icons install-desktop install-appdata PREFIX="$out"

    mkdir -p "$out/bin" "$out/etc/udev/rules.d"
    cp ${launcher} "$out/bin/steam"
    chmod +x "$out/bin/steam"

    cp ./subprojects/steam-devices/*.rules "$out/etc/udev/rules.d/"
    substituteInPlace "$out/etc/udev/rules.d/60-steam-input.rules" \
      --replace-fail "/bin/sh" "${bash}/bin/bash"

    rm "$out/share/applications/steam.desktop"
    substitute steam.desktop "$out/share/applications/steam.desktop" \
      --replace-fail /usr/bin/steam steam

    runHook postInstall
  '';

  passthru = {
    inherit bootstrap;
    updateScript = ./update-arm64.py;
    tests.launcher = callPackage ./tests-arm64.nix { };
  };

  meta = legacySteam.meta // {
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
