{
  lib,
  stdenv,
  steam-unwrapped,
  fex-steam,
  proton-ge-bin,
  buildFHSEnv,
  writeShellScript,
  extraPkgs ? pkgs: [ ], # extra packages to add to targetPkgs
  extraLibraries ? pkgs: [ ], # extra packages to add to multiPkgs
  extraProfile ? "", # string to append to profile
  extraPreBwrapCmds ? "", # extra commands to run before calling bubblewrap
  extraBwrapArgs ? [ ], # extra arguments to pass to bubblewrap (real default is at usage site)
  extraArgs ? "", # arguments to always pass to steam
  extraEnv ? { }, # Environment variables to pass to Steam
  compatPackages ? lib.optionals (stdenv.hostPlatform.isAarch64 && stdenv.hostPlatform.isLinux) [
    proton-ge-bin
    fex-steam
  ],
  privateTmp ? true, # if the steam bubblewrap should isolate /tmp
}:
let
  isArm64 = stdenv.hostPlatform.isAarch64 && stdenv.hostPlatform.isLinux;
  buildRuntimeEnv =
    {
      extraPkgs ? pkgs: [ ],
      extraLibraries ? pkgs: [ ],
      extraProfile ? "",
      extraPreBwrapCmds ? "",
      extraBwrapArgs ? [ ],
      extraEnv ? { },
      compatPackages ? [ ],
      privateTmp ? true,
      ...
    }@args:
    buildFHSEnv (
      (removeAttrs args [
        "extraPkgs"
        "extraLibraries"
        "extraProfile"
        "extraPreBwrapCmds"
        "extraBwrapArgs"
        "extraArgs"
        "extraEnv"
        "compatPackages"
      ])
      // {
        inherit privateTmp;

        # ARM64 Steam and Proton use native host libraries. FEX supplies the
        # x86 userspace for Linux games separately, rather than using ARM32
        # multilib packages here.
        multiArch = !isArm64;
        includeClosures = true;

        # https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/main/docs/distro-assumptions.md#command-line-tools
        targetPkgs =
          pkgs:
          with pkgs;
          [
            bash
            coreutils
            file
            lsb-release # not documented, called from Big Picture
            pciutils # not documented, complains about lspci on startup
            (if isArm64 then glibc.bin else glibc_multi.bin)
            usbutils # not documented, complains about lsusb on startup (needed for the 'Enter VR Mode' button to appear)
            xdg-utils # calls xdg-open occasionally
            xz
            zenity

            # crashes on startup if it can't find libx11 locale files
            (pkgs.runCommand "xorg-locale" { } ''
              mkdir -p $out
              ln -s ${libx11}/share $out/share
            '')
          ]
          ++ lib.optionals isArm64 [
            curl
            findutils
            gnugrep
            gnused
            gnutar
            gzip
            lsof # steamwebhelper authenticates local IPC clients using lsof
            procps
            python3
            unzip
            util-linux # steamwebhelper.sh invokes taskset
            xdg-user-dirs
            zstd
          ]
          ++ extraPkgs pkgs;

        # https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/main/docs/distro-assumptions.md#shared-libraries
        multiPkgs =
          pkgs:
          with pkgs;
          [
            glibc
            libxcrypt
            libGL

            libdrm
            libgbm
            udev
            libudev0-shim
            libva
            vulkan-loader

            networkmanager
            # not documented, used for network status things in Big Picture
            # FIXME: figure out how to only build libnm?
            libcap # not documented, required by srt-bwrap
          ]
          ++ lib.optionals isArm64 [
            SDL2
            alsa-lib
            at-spi2-core
            cairo
            cups
            dbus
            expat
            fontconfig
            freetype
            gdk-pixbuf
            glib
            (pkgs.callPackage ./gtk2-for-steam.nix { })
            gtk3
            ibus
            libice
            libpulseaudio
            libsm
            libx11
            libxcb
            libxcomposite
            libxcursor
            libxdamage
            libxext
            libxfixes
            libxi
            libxinerama
            libxkbcommon
            libxrandr
            libxrender
            libxtst
            nspr
            nss
            openal
            pango
            pipewire
            wayland
          ]
          ++ extraLibraries pkgs;

        profile = ''
          # prevents log spam from SteamRT GTK trying to load host GIO modules
          unset GIO_EXTRA_MODULES

          # udev event notifications don't work reliably inside containers.
          # SDL2 already tries to automatically detect flatpak and pressure-vessel
          # and falls back to inotify-based discovery [1]. We make SDL2 do the
          # same by telling it explicitly.
          #
          # [1] <https://github.com/libsdl-org/SDL/commit/8e2746cfb6e1f1a1da5088241a1440fd2535e321>
          export SDL_JOYSTICK_DISABLE_UDEV=1

          # This is needed for IME (e.g. iBus, fcitx5) to function correctly on non-CJK locales
          # https://github.com/ValveSoftware/steam-for-linux/issues/781#issuecomment-2004757379
          export GTK_IM_MODULE='xim'

          # See https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/main/docs/distro-assumptions.md#graphics-driver
          export LIBGL_DRIVERS_PATH=/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri
          export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d:/run/opengl-driver-32/share/glvnd/egl_vendor.d
          export LIBVA_DRIVERS_PATH=/run/opengl-driver/lib/dri:/run/opengl-driver-32/lib/dri
          export VDPAU_DRIVER_PATH=/run/opengl-driver/lib/vdpau:/run/opengl-driver-32/lib/vdpau

          # Redirect /etc/localtime to our faked location in /usr/share to make pressure-vessel happy
          # See: https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/be8ef5fae5ce14e13c18b255a793a2be8ab03ee5/pressure-vessel/runtime.c#L4183-4245
          tz="$(readlink -f /etc/localtime | grep -P -o '(?<=/zoneinfo/).*$')"
          ln -sf /usr/share/zoneinfo/$tz /etc/localtime

          set -a
          ${lib.toShellVars (removeAttrs extraEnv [ "STEAM_EXTRA_COMPAT_TOOLS_PATHS" ])}
          set +a

          ${extraProfile}
        '';

        # The FHS builder traverses the profile's closure. Register compatibility
        # tools in the outer launcher so their foreign userspace and /etc files
        # cannot be merged into the native client environment. The launcher
        # still retains the tools as dependencies and passes this variable in.
        extraPreBwrapCmds = ''
          ${extraPreBwrapCmds}
          ${lib.optionalString (extraEnv ? STEAM_EXTRA_COMPAT_TOOLS_PATHS) ''
            set -a
            ${lib.toShellVars (lib.getAttrs [ "STEAM_EXTRA_COMPAT_TOOLS_PATHS" ] extraEnv)}
            set +a
          ''}
          ${lib.optionalString (!(extraEnv ? STEAM_EXTRA_COMPAT_TOOLS_PATHS) && compatPackages != [ ]) ''
            if [[ ! -v STEAM_EXTRA_COMPAT_TOOLS_PATHS ]]; then
              export STEAM_EXTRA_COMPAT_TOOLS_PATHS=${
                lib.escapeShellArg (lib.makeSearchPathOutput "steamcompattool" "" compatPackages)
              }
            fi
          ''}
        '';

        # Steam expects /sbin/ldconfig to exist, and since SinceRT3
        # symlinking it results in a symlink loop in nested containers.
        # Thus, just copy it.
        extraBuildCommands = ''
          cp -f $out/usr/{bin,sbin}/ldconfig
        '';

        extraBwrapArgs = [
          # pressure-vessel expects to find the timezone info under /usr,
          # and falls back to weird behaviors otherwise
          "--bind /etc/zoneinfo /usr/share/zoneinfo"

          # Steam will dump crash reports here, make those more accessible
          "--bind-try /tmp/dumps /tmp/dumps"
        ]
        ++ extraBwrapArgs;
      }
    );
in
buildRuntimeEnv {
  pname = "steam";
  inherit (steam-unwrapped) version meta;

  extraPkgs = pkgs: [ steam-unwrapped ] ++ extraPkgs pkgs;
  inherit compatPackages;
  inherit
    extraLibraries
    extraProfile
    extraPreBwrapCmds
    extraBwrapArgs
    extraEnv
    privateTmp
    ;

  runScript = writeShellScript "steam-wrapped" ''
    ${lib.optionalString isArm64 ''
      if [[ $(getconf PAGESIZE) != 4096 ]]; then
        echo "Steam's ARM64 client requires a 4 KiB page kernel; run this launcher inside a 4 KiB VM such as muvm." >&2
        exit 1
      fi
    ''}
    exec steam ${extraArgs} "$@"
  '';

  extraInstallCommands = ''
    ln -s ${steam-unwrapped}/share $out/share
  '';

  passthru =
    let
      makeSteamRun =
        package:
        buildRuntimeEnv {
          inherit (steam-unwrapped) version;
          pname = "steam-run";

          extraPkgs = pkgs: package ++ extraPkgs pkgs;

          inherit
            extraLibraries
            extraProfile
            extraPreBwrapCmds
            extraBwrapArgs
            extraEnv
            privateTmp
            ;

          runScript = writeShellScript "steam-run" ''
            if [ $# -eq 0 ]; then
              echo "Usage: steam-run command-to-run args..." >&2
              exit 1
            fi

            exec "$@"
          '';

          meta = {
            description = "Run commands in the same FHS environment that is used for Steam";
            mainProgram = "steam-run";
            name = "steam-run";
            license = lib.licenses.mit;
          };
        };
    in
    {
      inherit buildRuntimeEnv;
      inherit compatPackages;

      run = makeSteamRun [ steam-unwrapped ];
      run-free = makeSteamRun [ ];
    };
}
