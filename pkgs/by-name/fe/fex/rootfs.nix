{
  lib,
  stdenvNoCC,
  buildPackages,
  closureInfo,
  python3,
  x86Packages,
  extraPackages ? p: [ ],
}:

let
  packages =
    p:
    with p;
    map lib.getLib [
      glibc
      glibc.bin
      gcc.cc.lib
      libxcrypt
      libGL
      libdrm
      libgbm
      mesa
      udev
      libudev0-shim
      libva
      vulkan-loader
      alsa-lib
      libpulseaudio
      openal
      libx11
      libxcb
      libxrandr
      libxrender
      libxext
      libxi
      libxcursor
      libxfixes
      libxcomposite
      libxdamage
      libxtst
      libxinerama
      fontconfig
      freetype
      cairo
      pango
      glib
      gtk3
      (p.callPackage ../../st/steam/gtk2-for-steam.nix { })
      dbus
      sdl12-compat
      SDL2
      sdl3
      networkmanager
      libcap
      zlib
      zstd
    ]
    ++ extraPackages p;

  packages64 =
    packages x86Packages
    ++ (with x86Packages; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      gnutar
      gzip
      xz
      # Keep useful runtime commands while foreign library roots select their
      # runtime outputs instead of dragging development tools into both ABIs.
      glib.bin
      fontconfig.bin
      dbus
      zstd.bin
      glibcLocales
    ]);
  packages32 = packages x86Packages.pkgsi686Linux;
  closure64 = closureInfo { rootPaths = packages64; };
  closure32 = closureInfo { rootPaths = packages32; };

  # Generate an x86 cache with x86 ldconfig even when the builder is ARM64.
  # This is a build-time operation and must not depend on FEX or binfmt_misc.
  ldconfig = "${x86Packages.pkgsi686Linux.glibc.bin}/bin/ldconfig";
  ldconfigCommand =
    lib.optionals (!stdenvNoCC.buildPlatform.isx86) [
      "${buildPackages.qemu-user}/bin/qemu-i386"
    ]
    ++ [ ldconfig ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "fex-rootfs";
  version = "1";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall
    python3 ${./rootfs.py} \
      --output "$out" \
      --closure64 ${closure64}/store-paths \
      --closure32 ${closure32}/store-paths \
      --packages64 ${lib.escapeShellArg (builtins.toJSON (map toString packages64))} \
      --packages32 ${lib.escapeShellArg (builtins.toJSON (map toString packages32))} \
      --ldconfig ${lib.escapeShellArg (builtins.toJSON ldconfigCommand)}
    runHook postInstall
  '';

  # The rootfs contains already-fixed-up x86 libraries. In particular, do not
  # run the native architecture's strip or patchelf over their closure.
  dontFixup = true;
  doInstallCheck = true;
  installCheckPhase = ''
    python3 ${./rootfs.py} --check "$out"
  '';

  passthru = {
    graphicsProvider = "${finalAttrs.finalPackage}/graphics-provider.json";
    inherit x86Packages closure64 closure32;
    rootPaths = packages64 ++ packages32;
  };

  meta = {
    description = "Nix-managed x86-64 and i386 userspace and graphics provider for FEX";
    homepage = "https://github.com/FEX-Emu/FEX";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
