{
  lib,
  stdenvNoCC,
  buildPackages,
  closureInfo,
  fex,
  fex-rootfs,
  python3,
  patchelf,
  vulkan-loader,
  libGL,
  libdrm,
  pkgsCross,
}:

let
  steamFex = fex.override { withSteamSupport = true; };
  runtimeClosure = closureInfo {
    rootPaths = [
      steamFex
      vulkan-loader
      libGL
      libdrm
    ];
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "fex-steam";
  inherit (steamFex) version;

  outputs = [
    "out"
    "steamcompattool"
  ];
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  nativeBuildInputs = [
    python3
    patchelf
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$steamcompattool"
    python3 ${./install.py} \
      --source ${steamFex} \
      --destination "$steamcompattool" \
      --closure ${runtimeClosure}/store-paths \
      --rootfs ${fex-rootfs}
    cp ${./launcher.py} "$steamcompattool/fex-steam-launch"
    substituteInPlace "$steamcompattool/fex-steam-launch" \
      --replace-fail '@python@' '${python3}/bin/python3' \
      --replace-fail '@rootfs@' '${fex-rootfs}'
    chmod +x "$steamcompattool/fex-steam-launch"
    ln -s "$steamcompattool/fex-steam-launch" "$out/bin/fex-steam"
    cat > "$steamcompattool/compatibilitytool.vdf" <<'EOF'
    "compatibilitytools"
    {
      "compat_tools"
      {
        "fex-nix"
        {
          "install_path" "."
          "display_name" "FEX (Nix)"
          "from_oslist" "linux"
          "to_oslist" "linux"
        }
      }
    }
    EOF
    cat > "$steamcompattool/toolmanifest.vdf" <<'EOF'
    "manifest"
    {
      "version" "2"
      "commandline" "/fex-steam-launch %verb% --"
      "use_tool_subprocess_reaper" "1"
      "compatmanager_layer_name" "fex"
    }
    EOF
    runHook postInstall
  '';

  # install.py gives the portable depot its own relative RPATHs. The guest
  # thunks are foreign ELF files and must not be fixed up as native binaries.
  dontFixup = true;
  doInstallCheck = true;
  nativeInstallCheckInputs = [
    buildPackages.binutils
    pkgsCross.gnu64.stdenv.cc
    pkgsCross.gnu32.stdenv.cc
  ];
  installCheckPhase = ''
    runHook preInstallCheck
    python3 ${./check.py} --depot "$steamcompattool" --source ${steamFex}
    ${lib.optionalString
      (stdenvNoCC.buildPlatform.isAarch64 && stdenvNoCC.buildPlatform == stdenvNoCC.hostPlatform)
      ''
        if [ "$(getconf PAGESIZE)" = 4096 ]; then
          smoke_dir="$(mktemp -d)"
          export FEX_ROOTFS=${fex-rootfs}
          export FEX_PORTABLE=1
          export FEX_SILENTLOG=0
          export STEAM_COMPAT_DATA_PATH="$smoke_dir"
          export STEAM_COMPAT_GRAPHICS_PROVIDER=${fex-rootfs}/graphics-provider.json
          set -x
          timeout 60 "$steamcompattool/FEXCompatTool" ${fex-rootfs}/usr/bin/true
          LIBGL_DRIVERS_PATH=/__fex_smoke_native_only__ \
            timeout 60 "$out/bin/fex-steam" ${fex-rootfs}/usr/bin/env \
            > "$smoke_dir/guest-environment"
          grep -Fx 'LIBGL_DRIVERS_PATH=/usr/lib64/dri:/usr/lib32/dri' \
            "$smoke_dir/guest-environment"
          grep -Fx 'tu_override_uncached_as_cache_coherent=true' \
            "$smoke_dir/guest-environment"
          grep -Fx 'DOTNET_EnableWriteXorExecute=0' \
            "$smoke_dir/guest-environment"
          for bits in 64 32; do
            compiler=${pkgsCross.gnu64.stdenv.cc}/bin/${pkgsCross.gnu64.stdenv.cc.targetPrefix}cc
            interpreter=/lib64/ld-linux-x86-64.so.2
            if [ "$bits" = 32 ]; then
              compiler=${pkgsCross.gnu32.stdenv.cc}/bin/${pkgsCross.gnu32.stdenv.cc.targetPrefix}cc
              interpreter=/lib/ld-linux.so.2
            fi
            "$compiler" -DGUEST_BITS="$bits" ${./guest-graphics-probe.c} \
              -o "$smoke_dir/graphics$bits"
            patchelf --set-interpreter "$interpreter" --remove-rpath "$smoke_dir/graphics$bits"
          done
          (
            unset MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER LIBGL_KOPPER_DISABLE
            # Test the actual exec path across both guest ABIs, including the
            # RootFS's 64-bit Bash launching a 32-bit game.
            timeout 60 "$out/bin/fex-steam" "$smoke_dir/graphics64" \
              --exec "$smoke_dir/graphics32" --exec "$smoke_dir/graphics64"
            for bits in 64 32; do
              timeout 60 "$out/bin/fex-steam" ${fex-rootfs}/bin/bash \
                -c 'exec "$1"' -- "$smoke_dir/graphics$bits"
            done
            STEAM_COMPAT_FEX_CONFIG=ThunksDB_Vulkan:0 timeout 60 \
              "$out/bin/fex-steam" "$smoke_dir/graphics64" --native
          )
          # Preload the Vulkan guest thunk into a C executable, which does not
          # otherwise load libstdc++. This catches missing guest DT_NEEDED.
          FEX_ENV=LD_PRELOAD=libvulkan.so.1 timeout 60 \
            "$out/bin/fex-steam" ${fex-rootfs}/usr/bin/true
          ${pkgsCross.gnu64.stdenv.cc}/bin/${pkgsCross.gnu64.stdenv.cc.targetPrefix}cc \
            -DEXPECT_FEX_VULKAN_THUNK ${./vulkan-getter-test.c} -ldl -o "$smoke_dir/vulkan-getter64"
          ${pkgsCross.gnu32.stdenv.cc}/bin/${pkgsCross.gnu32.stdenv.cc.targetPrefix}cc \
            ${./vulkan-getter-test.c} -ldl -o "$smoke_dir/vulkan-getter32"
          patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \
            --remove-rpath "$smoke_dir/vulkan-getter64"
          patchelf --set-interpreter /lib/ld-linux.so.2 \
            --remove-rpath "$smoke_dir/vulkan-getter32"
          for bits in 64 32; do
            timeout 60 "$out/bin/fex-steam" "$smoke_dir/vulkan-getter$bits"
          done
          # The Steam client can supply an empty options string. This must
          # still select our 64-bit Vulkan thunk, not silently load guest Mesa.
          STEAM_COMPAT_FEX_CONFIG= timeout 60 \
            "$out/bin/fex-steam" "$smoke_dir/vulkan-getter64"
          timeout 60 "$steamcompattool/FEXCompatTool" \
            ${fex-rootfs}/lib/ld-linux.so.2 --help > "$smoke_dir/i686-loader-help"
          grep -q 'Usage:' "$smoke_dir/i686-loader-help"
          # A typical Steam game has no Nix RUNPATH. Require each guest loader
          # to find non-glibc dependencies through its compiled default cache.
          for bits in 64 32; do
            cp -L ${fex-rootfs}/usr/lib"$bits"/libGL.so.1 "$smoke_dir/libGL$bits.so"
            chmod u+w "$smoke_dir/libGL$bits.so"
            patchelf --remove-rpath "$smoke_dir/libGL$bits.so"
            if [ "$bits" = 64 ]; then
              guest_loader=${fex-rootfs}/lib64/ld-linux-x86-64.so.2
            else
              guest_loader=${fex-rootfs}/lib/ld-linux.so.2
            fi
            LD_LIBRARY_PATH= timeout 60 "$steamcompattool/FEXCompatTool" \
              "$guest_loader" --list "$smoke_dir/libGL$bits.so" \
              > "$smoke_dir/libGL$bits-dependencies"
            grep -q 'libGLX.so.0 =>' "$smoke_dir/libGL$bits-dependencies"
          done
          rm -rf "$smoke_dir"
          set +x
        fi
      ''
    }
    runHook postInstallCheck
  '';

  passthru = {
    inherit steamFex;
    rootfs = fex-rootfs;
    emulatorDescription = "${finalAttrs.finalPackage.steamcompattool}/emulator.json";
    graphicsProvider = "${fex-rootfs}/graphics-provider.json";
    defaultThunks = {
      Vulkan = true;
      GL = false;
      drm = false;
      asound = false;
      WaylandClient = false;
    };
    # FEX 2608 does not build a 32-bit Vulkan guest library. Its 32-bit Vulkan
    # games use the RootFS driver, while GL/EGL thunks support both guest ABIs.
    thunkArchitectures = {
      Vulkan = [ "x86_64-linux-gnu" ];
      GL = [
        "x86_64-linux-gnu"
        "i386-linux-gnu"
      ];
    };
    tests.protocol =
      buildPackages.runCommand "fex-steam-protocol-tests"
        {
          nativeBuildInputs = [ buildPackages.python3 ];
        }
        ''
          cp ${./launcher.py} launcher.py
          cp ${./install.py} install.py
          python3 ${./tests.py}
          touch "$out"
        '';
    tests.guestGraphics =
      buildPackages.runCommand "fex-steam-guest-graphics-tests"
        { nativeBuildInputs = [ buildPackages.stdenv.cc ]; }
        ''
          $CXX -std=c++20 -Wall -Wextra -Werror -O2 \
            -I${../fex} ${./guest-graphics-test.cpp} -o guest-graphics-tests
          ./guest-graphics-tests
          touch "$out"
        '';
  };

  meta = {
    description = "Steam compatibility tool for x86 Linux games on ARM64, with a Nix-managed userspace";
    homepage = "https://github.com/FEX-Emu/FEX";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "fex-steam";
  };
})
