{
  lib,
  runCommand,
  fetchurl,
  libarchive,
  replaceVars,
  writeShellScript,
  bash,
  coreutils,
  gnugrep,
  gnused,
  util-linuxMinimal,
  shellcheck,
}:

let
  # Exercise the actual upstream launcher rather than reimplementing its
  # SteamRT branch in a fixture. The native client is replaced below so this
  # test can also run on an x86 build machine.
  components = (lib.importJSON ./arm64-sources.json).components;
  archive =
    name:
    fetchurl {
      url = "https://client-update.steamstatic.com/${components.${name}.file}";
      inherit (components.${name}) sha256;
    };
  upstreamLauncher = archive "steam_linuxarm64";
  x86Sdk = archive "bins_sdk_linuxarm64";
  arm64Sdk = archive "bins_sdk_linuxarm64_linuxarm64";
  client = writeShellScript "steam-arm64-test-client" ''
    printf 'call\n' >> "$HOME/calls"
    printf 'arg:%s\n' "$@" >> "$HOME/calls"
    printf 'runtime:%s\n' "''${STEAM_RUNTIME-unset}" >> "$HOME/calls"
    printf 'runtime-library-path:%s\n' "''${STEAM_RUNTIME_LIBRARY_PATH-unset}" >> "$HOME/calls"
    printf 'compat:%s\n' "''${STEAM_EXTRA_COMPAT_TOOLS_PATHS-unset}" >> "$HOME/calls"
    printf 'reloaded:%s\n' "''${STEAM_TEST_RELOADED-unset}" >> "$HOME/calls"
    if [ "''${1-}" = -forcesteamupdate ]; then
      if [ -f "$HOME/recover-update" ]; then
        attempts=0
        if [ -f "$HOME/update-attempts" ]; then
          attempts="$(cat "$HOME/update-attempts")"
        fi
        attempts=$((attempts + 1))
        printf '%s\n' "$attempts" > "$HOME/update-attempts"
        if [ "$attempts" -ge 2 ]; then
          touch "$PWD/steamrtarm64/libcef.so" "$PWD/linuxarm64/steamclient.so"
        fi
      fi
      exit 254
    fi
    if [ -f "$HOME/request-restart" ] && [ ! -f "$HOME/restarted" ]; then
      touch "$HOME/restarted"
      sed -i '2a export STEAM_TEST_RELOADED=updated' "$PWD/steam.sh"
      exit 42
    fi
    if [ -f "$HOME/fail-client" ]; then
      exit 17
    fi
  '';
  bootstrap =
    runCommand "steam-arm64-test-bootstrap"
      {
        nativeBuildInputs = [ libarchive ];
      }
      ''
        mkdir -p "$out/steamrtarm64" "$out/public" "$out/linuxarm64"
        bsdtar -xf ${upstreamLauncher} -C "$out" steam.sh
        cp ${client} "$out/steamrtarm64/steam"
        chmod +x "$out/steamrtarm64/steam"
        touch "$out/steamrtarm64/libSDL3.so.0" "$out/steamrtarm64/libavcodec.so.62"
        touch "$out/steamrtarm64/steamclient.so" "$out/steamrtarm64/steamwebhelper" "$out/steamrtarm64/libcef.so"
        touch "$out/public/steambootstrapper_english.txt"

        # Use the ELF identification bytes from the real Valve SDK archives.
        # The client execution is mocked above; these header fixtures test SDK
        # architecture checks without pretending to execute the SDK libraries.
        bsdtar -xf ${x86Sdk} -C "$out" linux32/steamclient.so linux64/steamclient.so
        bsdtar -xf ${arm64Sdk} -C "$out" linuxarm64/steamclient.so
        for arch in linux32 linux64 linuxarm64; do
          head -c 20 "$out/$arch/steamclient.so" > "$TMPDIR/header"
          mv -f "$TMPDIR/header" "$out/$arch/steamclient.so"
        done

        # The shared manifest actually installs this SteamRT3c runtime under
        # steamrt64, not steamrtarm64. Its tools are x86 executables.
        steamrt="$out/steamrt64/pv-runtime/steam-runtime-steamrt"
        mkdir -p "$steamrt/bin" "$steamrt/pressure-vessel/libexec/steam-runtime-tools-0"
        touch "$steamrt/bin/example-tool"
        touch "$steamrt/pressure-vessel/libexec/steam-runtime-tools-0/logger-0.bash"
        touch "$steamrt/pressure-vessel/libexec/steam-runtime-tools-0/srt-logger"
        mkdir -p "$out/ubuntu12_32/steam-runtime"
        touch "$out/ubuntu12_32/steam-runtime/scout-preserved"
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
runCommand "steam-arm64-launcher-tests"
  {
    nativeBuildInputs = [
      bash
      coreutils
      gnugrep
      gnused
      shellcheck
    ];
  }
  ''
    mkdir -p "$TMPDIR/fresh" "$TMPDIR/existing" "$TMPDIR/conflict" "$TMPDIR/restart" "$TMPDIR/sdk"

    shellcheck ${launcher}

    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" \
      STEAM_RUNTIME=invalid STEAM_RUNTIME_LIBRARY_PATH=invalid \
      STEAM_EXTRA_COMPAT_TOOLS_PATHS=/proton:/fex \
      bash ${launcher} 'steam://run/123' 'argument with spaces'
    clientRoot="$TMPDIR/fresh/data/Steam"
    test "$(readlink "$TMPDIR/fresh/.steam/sdkarm64")" = "$clientRoot/linuxarm64"
    test "$(readlink "$TMPDIR/fresh/.steam/sdk64")" = "$clientRoot/linux64"
    test "$(readlink "$TMPDIR/fresh/.steam/sdk32")" = "$clientRoot/linux32"
    test "$(grep -c '^call$' "$TMPDIR/fresh/calls")" = 2
    grep -Fx 'arg:steam://run/123' "$TMPDIR/fresh/calls"
    grep -Fx 'arg:argument with spaces' "$TMPDIR/fresh/calls"
    test "$(grep -c '^runtime:unset$' "$TMPDIR/fresh/calls")" = 2
    test "$(grep -c '^runtime-library-path:unset$' "$TMPDIR/fresh/calls")" = 2
    test "$(grep -c '^compat:/proton:/fex$' "$TMPDIR/fresh/calls")" = 2
    test -f "$clientRoot/ubuntu12_32/steam-runtime/scout-preserved"
    test ! -e "$clientRoot/steamrtarm64/pv-runtime"
    cmp "$clientRoot/steam.sh" ${bootstrap}/steam.sh

    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" \
      bash ${launcher} 'steam://open/games'
    test "$(grep -c '^call$' "$TMPDIR/fresh/calls")" = 3
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/fresh/calls")" = 1
    grep -Fx 'arg:steam://open/games' "$TMPDIR/fresh/calls"

    # A client update may change the codec SONAME. Do not downgrade a complete
    # installation merely because the pinned bootstrap used an older version.
    mv "$clientRoot/steamrtarm64/libavcodec.so.62" "$clientRoot/steamrtarm64/libavcodec.so.63"
    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" bash ${launcher}
    test ! -e "$clientRoot/steamrtarm64/libavcodec.so.62"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/fresh/calls")" = 1

    # Missing bootstrap libraries must be repaired even when the executable
    # and ready marker survived an interrupted installation.
    rm "$clientRoot/steamrtarm64/libSDL3.so.0" "$clientRoot/steamrtarm64/libavcodec.so.63"
    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" bash ${launcher}
    test -e "$clientRoot/steamrtarm64/libSDL3.so.0"
    test -e "$clientRoot/steamrtarm64/libavcodec.so.62"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/fresh/calls")" = 2

    # A successful updater exit is insufficient when client files are missing.
    rm "$clientRoot/steamrtarm64/libcef.so" "$clientRoot/linuxarm64/steamclient.so"
    touch "$TMPDIR/fresh/recover-update"
    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" bash ${launcher}
    test "$(cat "$TMPDIR/fresh/update-attempts")" = 2
    test -f "$clientRoot/.nixpkgs-steam-arm64-ready"
    rm "$TMPDIR/fresh/recover-update" "$clientRoot/steamrtarm64/libcef.so"
    status=0
    env HOME="$TMPDIR/fresh" XDG_DATA_HOME="$TMPDIR/fresh/data" \
      bash ${launcher} || status=$?
    test "$status" = 1
    test ! -e "$clientRoot/.nixpkgs-steam-arm64-ready"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/fresh/calls")" = 7

    # Seed all SDKs before login, repair missing/wrong-architecture copies,
    # and preserve an already self-updated SDK with the correct architecture.
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    sdkRoot="$TMPDIR/sdk/data/Steam"
    printf 'newer SDK payload\n' >> "$sdkRoot/linux64/steamclient.so"
    cp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"
    rm "$sdkRoot/linux32/steamclient.so"
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    cmp "$sdkRoot/linux32/steamclient.so" ${bootstrap}/linux32/steamclient.so
    cmp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/sdk/calls")" = 2

    cp "$sdkRoot/linuxarm64/steamclient.so" "$sdkRoot/linux32/steamclient.so"
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    cmp "$sdkRoot/linux32/steamclient.so" ${bootstrap}/linux32/steamclient.so
    cmp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/sdk/calls")" = 3

    cp "$sdkRoot/linux64/steamclient.so" "$sdkRoot/linuxarm64/steamclient.so"
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    cmp "$sdkRoot/linuxarm64/steamclient.so" ${bootstrap}/linuxarm64/steamclient.so
    cmp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/sdk/calls")" = 4

    cp "$sdkRoot/linux32/steamclient.so" "$sdkRoot/linux64/steamclient.so"
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    cmp "$sdkRoot/linux64/steamclient.so" ${bootstrap}/linux64/steamclient.so
    test "$(grep -c '^arg:-forcesteamupdate$' "$TMPDIR/sdk/calls")" = 5

    # Repairing unrelated bootstrap libraries must not overwrite a newer SDK.
    printf 'newer SDK payload\n' >> "$sdkRoot/linux64/steamclient.so"
    cp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"
    rm "$sdkRoot/steamrtarm64/libSDL3.so.0"
    env HOME="$TMPDIR/sdk" XDG_DATA_HOME="$TMPDIR/sdk/data" bash ${launcher}
    cmp "$sdkRoot/linux64/steamclient.so" "$TMPDIR/updated-sdk64"

    # Preserve an existing installation and its real x86 SteamRT directory.
    clientRoot="$TMPDIR/existing/library with spaces"
    mkdir -p "$TMPDIR/existing/.steam" "$clientRoot/steamrt64" \
      "$clientRoot/steamapps" "$clientRoot/userdata"
    touch "$clientRoot/steamrt64/keep" "$clientRoot/steamapps/keep" "$clientRoot/userdata/keep"
    ln -s "$clientRoot" "$TMPDIR/existing/.steam/steam"
    env HOME="$TMPDIR/existing" XDG_DATA_HOME="$TMPDIR/existing/data" \
      bash ${launcher} --reset 'steam://open/games'
    test -f "$clientRoot/steamrt64/keep"
    test -f "$clientRoot/steamapps/keep"
    test -f "$clientRoot/userdata/keep"
    test ! -e "$TMPDIR/existing/data/Steam"

    mkdir -p "$TMPDIR/conflict/.steam"
    printf 'user data\n' > "$TMPDIR/conflict/.steam/steam"
    if env HOME="$TMPDIR/conflict" XDG_DATA_HOME="$TMPDIR/conflict/data" \
        bash ${launcher}; then
      echo 'launcher unexpectedly replaced a non-symlink installation path' >&2
      exit 1
    fi
    grep -Fx 'user data' "$TMPDIR/conflict/.steam/steam"

    # An update-requested restart must reload steam.sh and preserve arguments.
    touch "$TMPDIR/restart/request-restart"
    env HOME="$TMPDIR/restart" XDG_DATA_HOME="$TMPDIR/restart/data" \
      bash ${launcher} 'steam://run/456' 'another argument'
    test "$(grep -c '^call$' "$TMPDIR/restart/calls")" = 3
    test "$(grep -c '^arg:steam://run/456$' "$TMPDIR/restart/calls")" = 2
    grep -Fx 'reloaded:updated' "$TMPDIR/restart/calls"

    touch "$TMPDIR/restart/fail-client"
    status=0
    env HOME="$TMPDIR/restart" XDG_DATA_HOME="$TMPDIR/restart/data" \
      bash ${launcher} || status=$?
    test "$status" = 17

    touch "$out"
  ''
