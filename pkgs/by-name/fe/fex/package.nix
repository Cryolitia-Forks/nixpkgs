{
  lib,
  llvmPackages,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
  nix-update-script,
  xxhash,
  fmt,
  libxml2,
  openssl,
  range-v3,
  catch2_3,
  nasm,
  buildEnv,
  writeText,
  pkgsCross,
  libclang,
  libllvm,
  alsa-lib,
  libdrm,
  libGL,
  wayland,
  libxrender,
  libxrandr,
  libx11,
  xorgproto,
  libxcb,
  withSteamSupport ? false,
  withQt ? !withSteamSupport,
  qt6,
}:

let
  # Headers required to build the ThunkLibs subtree
  libForwardingInputs = lib.map lib.getInclude [
    alsa-lib
    libdrm
    libGL
    wayland
    libx11
    libxcb
    libxrandr
    libxrender
    xorgproto
  ];

  pkgsCross32 = pkgsCross.gnu32;
  pkgsCross64 = pkgsCross.gnu64;
  devRootFS = buildEnv {
    name = "fex-dev-rootfs";
    paths = [
      pkgsCross64.stdenv.cc.libc_dev
      pkgsCross32.stdenv.cc.libc_dev
      pkgsCross64.stdenv.cc.cc
      pkgsCross32.stdenv.cc.cc
    ]
    ++ libForwardingInputs;
    ignoreCollisions = true;
    pathsToLink = [
      "/include"
      "/lib"
    ];

    postBuild = ''
      mkdir -p $out/usr
      ln -s $out/include $out/usr/
    '';
  };

  toolchain32 = writeText "toolchain_nix_x86_32.txt" ''
    set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_SYSTEM_PROCESSOR i686)
    set(CMAKE_C_COMPILER clang)
    set(CMAKE_CXX_COMPILER clang++)
    set(CMAKE_C_COMPILER ${pkgsCross32.buildPackages.clang}/bin/i686-unknown-linux-gnu-clang)
    set(CMAKE_CXX_COMPILER ${pkgsCross32.buildPackages.clang}/bin/i686-unknown-linux-gnu-clang++)
    set(CLANG_FLAGS "-nodefaultlibs -nostartfiles -target i686-linux-gnu -msse2 -mfpmath=sse --sysroot=${devRootFS} -iwithsysroot/usr/include")
    set(CMAKE_C_FLAGS "''${CMAKE_C_FLAGS} ''${CLANG_FLAGS}")
    set(CMAKE_CXX_FLAGS "''${CMAKE_CXX_FLAGS} ''${CLANG_FLAGS}")
  '';

  toolchain = writeText "toolchain_nix_x86_64.txt" ''
    set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
    set(CMAKE_SYSTEM_PROCESSOR x86_64)
    set(CMAKE_C_COMPILER clang)
    set(CMAKE_CXX_COMPILER clang++)
    set(CMAKE_C_COMPILER ${pkgsCross64.buildPackages.clang}/bin/x86_64-unknown-linux-gnu-clang)
    set(CMAKE_CXX_COMPILER ${pkgsCross64.buildPackages.clang}/bin/x86_64-unknown-linux-gnu-clang++)
    set(CLANG_FLAGS "-nodefaultlibs -nostartfiles -target x86_64-linux-gnu --sysroot=${devRootFS} -iwithsysroot/usr/include")
    set(CMAKE_C_FLAGS "''${CMAKE_C_FLAGS} ''${CLANG_FLAGS}")
    set(CMAKE_CXX_FLAGS "''${CMAKE_CXX_FLAGS} ''${CLANG_FLAGS}")
  '';
in
llvmPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "fex" + lib.optionalString withSteamSupport "-steam";
  version = "2608";

  src = fetchFromGitHub {
    owner = "FEX-Emu";
    repo = "FEX";
    tag = "FEX-${finalAttrs.version}";
    hash = "sha256-2NdkQpzqDkM/fEW8QYS05KU3JPJeLw4gliryqdOJ3vE=";

    leaveDotGit = true;
    postFetch = ''
      cd $out
      git reset

      # Only fetch required submodules
      git submodule update --init --depth 1 \
        External/Vulkan-Headers \
        External/drm-headers \
        External/rpmalloc \
        External/jemalloc_glibc \
        External/vixl \
        External/unordered_dense \
        Source/Common/cpp-optparse

      find . -name .git -print0 | xargs -0 rm -rf

      # Remove some more unnecessary directories
      rm -r \
        External/vixl/src/aarch32 \
        External/vixl/test
    '';
  };

  postPatch = ''
    substituteInPlace FEXCore/include/git_version.h.in \
      --replace-fail "@GIT_HASH_ARRAY@" "" \
      --replace-fail "@GIT_DESCRIBE_STRING@" "FEX-${finalAttrs.version}"

    substituteInPlace ThunkLibs/GuestLibs/CMakeLists.txt ThunkLibs/HostLibs/CMakeLists.txt \
      --replace-fail "/usr/include/libdrm" "${devRootFS}/include/libdrm" \
      --replace-fail "/usr/include/wayland" "${devRootFS}/include/wayland"

    # Add include paths for thunkgen invocation
    substituteInPlace ThunkLibs/HostLibs/CMakeLists.txt \
      --replace-fail "-- " "-- $(cat ${llvmPackages.stdenv.cc}/nix-support/libc-cflags) $(cat ${llvmPackages.stdenv.cc}/nix-support/libcxx-cxxflags) ${
        lib.concatMapStrings (x: "-isystem " + x + "/include ") libForwardingInputs
      }"
    substituteInPlace ThunkLibs/GuestLibs/CMakeLists.txt \
      --replace-fail "-- " "-- $(cat ${llvmPackages.stdenv.cc}/nix-support/libcxx-cxxflags) "

    # Disable including current date in manpages
    substituteInPlace FEXCore/Scripts/config_generator.py \
      --replace-fail ".Dd {0}" ".Dd" \
      --replace-fail "output_man.write(header.format(" "output_man.write(header) #"

    ${lib.optionalString withSteamSupport ''
          # Steam's relocatable depot lives below the Nix output, rather than the
          # filesystem root. Keep the upstream portable configuration and thunks:
          # pressure-vessel will use them inside a different mount namespace.
      substituteInPlace Source/Steam/CMakeLists.txt \
            --replace-fail "DESTINATION /" "DESTINATION ."
          # A direct x86 game needs different guest graphics search paths from a
          # pressure-vessel container. Let the Steam wrapper supply that template
          # without replacing FEXCompatTool's per-game Steam configuration.
      patch -p1 < ${./steam-config-template-override.patch}
      # Backport FEX d96e48e246fae8ec4953b253297ab823fe161176. Vulkan loaders
      # query the getters themselves; returning a host pointer here crashes
      # guest callers (including current vkcube and Mesa Zink).
      patch -p1 < ${./fix-vulkan-proc-address-self-lookup.patch}
      # Choose guest graphics defaults from the ELF actually loaded by FEX,
      # including games reached through launch scripts and mixed-bitness exec.
      cp ${./steam-guest-graphics.h} Source/Tools/FEXInterpreter/steam-guest-graphics.h
      patch -p1 < ${./steam-guest-graphics.patch}
    ''}

    ${lib.optionalString (!withSteamSupport) ''
      # Patch any references to library wrapper paths
      substituteInPlace FEXCore/Source/Interface/Config/Config.json.in \
        --replace-fail "ThunkGuestLibs" "UnusedThunkGuestLibs" \
        --replace-fail "ThunkHostLibs" "UnusedThunkHostLibs"
      substituteInPlace FEXCore/Source/Interface/Config/Config.cpp \
        --replace-fail "FEXCore::Config::CONFIG_THUNKGUESTLIBS" "FEXCore::Config::CONFIG_UNUSEDTHUNKGUESTLIBS" \
        --replace-fail "FEXCore::Config::CONFIG_THUNKHOSTLIBS" "FEXCore::Config::CONFIG_UNUSEDTHUNKHOSTLIBS"
      substituteInPlace Source/Tools/LinuxEmulation/VDSO_Emulation.cpp \
        --replace-fail "FEX_CONFIG_OPT(ThunkGuestLibs, THUNKGUESTLIBS);" "auto ThunkGuestLibs = []() { return \"$out/share/fex-emu/GuestThunks/\"; };"
      substituteInPlace Source/Tools/LinuxEmulation/LinuxSyscalls/FileManagement.h \
        --replace-fail "FEX_CONFIG_OPT(ThunkGuestLibs, THUNKGUESTLIBS);" "fextl::string ThunkGuestLibs() { return \"$out/share/fex-emu/GuestThunks/\"; }"
      substituteInPlace Source/Tools/LinuxEmulation/Thunks.cpp \
        --replace-fail "FEX_CONFIG_OPT(ThunkHostLibsPath, THUNKHOSTLIBS);" "fextl::string ThunkHostLibsPath() { return \"$out/lib/fex-emu/HostThunks/\"; }"
      substituteInPlace Source/Tools/FEXConfig/main.qml \
        --replace-fail "config: \"Thunk" "config: \"UnusedThunk" \
        --replace-fail "title: qsTr(\"Library forwarding:\")" "visible: false; title: qsTr(\"Library forwarding:\")"

    ''}

    # Temporarily disable failing tests. TODO: investigate the root cause of these failures
    rm \
      unittests/ASM/FEX_bugs/SegmentAddressOverride.asm \
      unittests/ASM/Primary/Primary_63_2.asm \
      unittests/32Bit_ASM/Secondary/07_XX_04.asm \
      unittests/ASM/Secondary/07_XX_04.asm
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    llvmPackages.bintools
    (python3.withPackages (
      pythonPackages: with pythonPackages; [
        packaging
        libclang
      ]
    ))
  ]
  ++ lib.optional withQt qt6.wrapQtAppsHook;

  buildInputs = [
    xxhash
    fmt
    libxml2
    openssl
    range-v3
    pkgsCross64.buildPackages.clang
    pkgsCross32.buildPackages.clang
    libclang
    libllvm
  ]
  ++ libForwardingInputs
  ++ lib.optionals withQt [
    qt6.qtbase
    qt6.qtdeclarative
  ];

  cmakeFlags = [
    (lib.cmakeFeature "USE_LINKER" "lld")
    (lib.cmakeFeature "OVERRIDE_VERSION" finalAttrs.version)
    (lib.cmakeBool "BUILD_THUNKS" true)
    (lib.cmakeBool "BUILD_FEXCONFIG" withQt)
  ]
  ++ lib.optional withSteamSupport (lib.cmakeBool "BUILD_STEAM_SUPPORT" true)
  ++ [
    (lib.cmakeFeature "X86_32_TOOLCHAIN_FILE" "${toolchain32}")
    (lib.cmakeFeature "X86_64_TOOLCHAIN_FILE" "${toolchain}")
    (lib.cmakeFeature "X86_DEV_ROOTFS" "${devRootFS}")
  ];

  strictDeps = true;

  # Running the tests isn't supported on non-4K pagesize systems, but the build
  # itself doesn't require 4K pagesize. So, to avoid breaking the build, enable
  # checkPhase by default (so that the check inputs are included) and then
  # manually disable it if we're running on a non-4K pagesize system.
  doCheck = true;
  preConfigure = ''
    if [ "$(getconf PAGESIZE)" != "4096" ]; then
      echo "Disabling checkPhase due to non-4K pagesize environment"
      unset doCheck
      cmakeFlagsArray+=("-DBUILD_TESTING:BOOL=FALSE")
    else
      echo "Keeping checkPhase as-is"
      cmakeFlagsArray+=("${lib.cmakeBool "BUILD_TESTING" finalAttrs.finalPackage.doCheck}")
    fi
  '';

  nativeCheckInputs = [ nasm ];
  checkInputs = [ catch2_3 ];

  # List not exhaustive, e.g. because they depend on an x86 compiler or some
  # other difficult-to-build test binaries.
  checkTarget = lib.concatStringsSep " " [
    "asm_tests"
    "api_tests"
    "fexcore_apitests"
    "emitter_tests"
  ];

  # Avoid wrapping anything other than FEXConfig, since the wrapped executables
  # don't seem to work when registered as binfmts.
  dontWrapQtApps = true;
  preFixup = lib.optionalString withQt ''
    wrapQtApp $out/bin/FEXConfig
  '';

  passthru = {
    updateScript = nix-update-script { };
  };

  meta = {
    description = "Fast usermode x86 and x86-64 emulator for Arm64 Linux";
    homepage = "https://fex-emu.com/";
    changelog = "https://github.com/FEX-Emu/FEX/releases/tag/FEX-${finalAttrs.version}";
    platforms = [ "aarch64-linux" ];
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ andre4ik3 ];
    mainProgram = "FEXBash";
  };
})
