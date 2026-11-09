# Steam {#sec-steam}

## Steam in Nix {#sec-steam-nix}

Steam's Linux launcher installs a bootstrap into the user's home directory and then downloads the self-updating client. The x86 launcher uses Valve's Linux launcher archive. The native ARM64 launcher uses the ARM64 client archives, as described in [Steam on ARM64 Linux](#sec-steam-arm64). In both cases, the client and its updates are stored in the user's home directory rather than patched in the Nix store.

Nix problems and constraints:

- We don't have `/bin/bash` and many scripts point there. Same thing for `/usr/bin/python`.
- We don't have the dynamic loader in `/lib`.
- The original `steam.sh` script in `$HOME` is checked and rewritten by Steam. The ARM64 launcher preserves that original and generates a private adapted copy for execution, regenerating it when Steam updates the script.
- The steam binary cannot be patched, it's also checked.

The current approach to deploy Steam in NixOS is composing a FHS-compatible chroot environment, as documented [here](https://sandervanderburg.blogspot.com/2013/09/composing-fhs-compatible-chroot.html). This allows us to have binaries in the expected paths without disrupting the system and to avoid patching them to work in a non-FHS environment.

## How to play {#sec-steam-play}

Use `programs.steam.enable = true;` if you want to add steam to `systemPackages` and also enable a few workarounds as well as Steam controller support or other Steam supported controllers such as the DualShock 4 or Nintendo Switch Pro Controller.

## Steam on ARM64 Linux {#sec-steam-arm64}

The ARM64 integration is experimental. It is intended to run the native ARM64 Steam client and to launch x86 and x86-64 games through the appropriate compatibility tool. Package evaluation checks configuration and packaging interfaces. Client login and game compatibility require separate tests on ARM64 hardware.

On an `aarch64-linux` NixOS system, enable Steam with:

```nix
{
  nixpkgs.config.allowUnfree = true;
  programs.steam.enable = true;
}
```

The module selects the ARM64 bootstrap and a native FHS environment. It also makes the ARM64 `proton-ge-bin` and Linux FEX compatibility tools available to Steam. The extra x86 32-bit host graphics and audio support used on `x86_64-linux` is not enabled on ARM64. Running an x86 32-bit game through a compatibility tool does not require an ARM32 host graphics stack.

Valve's native Steam UI still requires the GTK2 library ABI. The Steam-specific GTK2 package ignores only the [planned-removal marker](https://github.com/NixOS/nixpkgs/issues/410814) for that dependency; it does not enable broken packages globally or suppress other GTK2 problems and known vulnerabilities.

Set `programs.steam.extraCompatPackages` to replace the default compatibility tools, or to `[ ]` to disable their registration and dependencies. For a standalone package, the corresponding argument is `pkgs.steam.override { compatPackages = [ ]; }`. `steam-run-free` does not include these compatibility tools or the unfree Steam client.

### Windows x86 and x86-64 games {#sec-steam-arm64-windows}

Select the ARM64 GE-Proton compatibility tool in the game's Steam compatibility settings. ARM64 Proton uses Wine and its bundled FEX component to execute x86 Windows code. This is a different execution path from running Linux ELF programs with FEX.

Install the ARM64 Steam Linux Runtime required by the selected Proton release. Current ARM64 Proton releases use Steam Linux Runtime 4.0, app ID `4185400`; the version is recorded in Proton's `toolmanifest.vdf`. Installing a different architecture's runtime does not satisfy that requirement. Steam may need to be restarted after adding a local compatibility tool.

Games that offer both Windows and Linux builds can be configured to use their Windows build with ARM64 Proton. Anti-cheat, game-specific dependencies, graphics requirements, and compatibility-tool regressions can still prevent an individual game from running.

### Linux x86 and x86-64 games {#sec-steam-arm64-linux}

Select **FEX (Nix)** in the Linux game's Steam compatibility settings. By default, its launcher runs the game directly with the Nix-managed FEX RootFS. This x86 userspace is separate from the native ARM64 environment used by the Steam client and Proton.

The Nix-managed RootFS includes x86-64 and i686 dynamic loaders, runtime libraries, and their Nix store closures. Its provider description advertises those x86 architectures; ARM64 programs continue to use the native environment. The compatibility tool is registered for Linux-to-Linux launches. Whether Steam selects it automatically for each game still requires client-side validation, so selecting FEX explicitly is the documented entry point.

The launcher enables Vulkan forwarding by default. FEX checks the architecture of each executable it loads and selects guest Mesa Zink for x86-64 OpenGL programs, including games reached through launch scripts. This uses the native host Vulkan driver. A 64-bit shell can still launch an i686 game: FEX restores the original driver environment for that child instead of passing the shell's Zink defaults into it. These defaults affect the guest environment; native graphics settings are restored before loading host thunk drivers.

No per-game Zink launch options are needed for these direct RootFS launches. An explicit Vulkan disable, a guest driver selected through `FEX_ENV`, or custom FEX app or template configuration retains control of graphics selection. Existing Steam Linux Runtime container paths and custom RootFS installations require separate validation. Check the game's actual renderer to confirm hardware acceleration.

For Turnip, the FEX tool also defaults `tu_override_uncached_as_cache_coherent` to `true`, matching Valve's FEX wrapper. On supported coherent UMA devices this avoids the [high cost of emulated x86 atomic accesses to uncached GPU memory](https://fex-emu.com/Scourge-of-emulation/#wait-uncached-memory-needs-to-work). This setting is scoped to the FEX game launch and preserves an explicitly supplied value.

The Linux FEX launcher also defaults `DOTNET_EnableWriteXorExecute` to `0`, disabling .NET's W^X JIT memory protection to work around [.NET runtime faults under FEX](https://github.com/FEX-Emu/FEX/issues/5991), also discussed in [FEX issue 5766](https://github.com/FEX-Emu/FEX/issues/5766). Explicit `DOTNET_EnableWriteXorExecute` or legacy `COMPlus_EnableWriteXorExecute` values are preserved, including empty values. The default is skipped for an explicit FEX guest override of either variable, or a custom FEX app or template configuration.

The RootFS does not automatically provide Valve's legacy Scout runtime or its complete set of older library ABIs. Games can require additional libraries. The native ARM64 client does not implicitly run Linux games inside the old `LD_LIBRARY_PATH` Steam Runtime, and an existing Scout directory does not guarantee that a new installation has extracted or uses that runtime.

When passed an existing Steam Linux Runtime entry point, the FEX launcher sets `STEAM_COMPAT_EMULATOR` and `STEAM_COMPAT_GRAPHICS_PROVIDER` before entering its pressure-vessel container. The tool does not automatically request a container runtime with `require_tool_appid`: Steam starts that outer runtime before the tool, so setting the emulator only inside the tool would be too late. Container integration therefore needs its own launch-path validation, as described by the [Steam compatibility tool interface](https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/main/docs/steam-compat-tool-interface.md) and [container runtime interface](https://gitlab.steamos.cloud/steamrt/steam-runtime-tools/-/blob/main/docs/container-runtime.md).

The emulator and provider variables are scoped to the Linux FEX compatibility tool. They must not be exported globally for Steam: ARM64 Proton uses its own FEX integration and must continue to select its native ARM64 runtime.

The FEX compatibility tool and its host and guest thunk libraries must come from a matching FEX build. Installing an unrelated FEX release or mixing its thunk libraries with Steam's downloaded copy can introduce incompatible runtime interfaces. Graphics library discovery must also work inside the game's pressure-vessel container, so a successful host-side FEX command alone does not establish game compatibility.

The packaged FEX 2608 provides Vulkan guest thunks for x86-64, but does not include an i686 Vulkan guest thunk. Successful i686 CPU execution or an x86-64 Vulkan test therefore does not establish hardware-accelerated Vulkan for a 32-bit Linux game. That game needs a working 32-bit guest graphics driver or another supported graphics path. This limitation concerns the Linux FEX tool; ARM64 Proton uses the separate Windows execution path described above.

### Kernel page size and graphics {#sec-steam-arm64-hardware}

The direct launcher currently targets kernels with 4 KiB pages. Check the running kernel with:

```ShellSession
getconf PAGESIZE
```

The expected result is `4096`. Some ARM64 systems, including common Apple Silicon Linux configurations, use larger pages. The launcher reports an unsupported page size in that case. Running inside a 4 KiB-page `muvm` guest is a possible approach for such hosts, but this package does not automatically set up that backend. `muvm` additionally requires KVM access and a working guest graphics path; selecting it is not sufficient to guarantee hardware acceleration.

The target machine must provide working ARM64 graphics drivers with the Vulkan or OpenGL features required by the game. A successful native graphics check does not establish acceleration in an emulated game. Check the game's actual renderer and selected device: `llvmpipe` or `lavapipe` indicates software rendering. Device enumeration alone also does not establish that creating a device and presenting frames works.

Validate client login, a 32-bit Windows game, a 64-bit Windows game, and Linux games for the supported x86 architectures on the actual hardware. Check rendering, audio, input devices, and launching after a Steam update. Tests that invoke FEX or Proton outside Steam supplement the required in-client game launch tests. These runtime checks remain separate from the module evaluation and packaging checks and must not be inferred from their success.

### Runtime validation {#sec-steam-arm64-validation}

Testing on a 4 KiB-page ARM64 NixOS machine has confirmed native client login and these Steam library launch paths:

| Game binary | Launch path | Observed result |
| --- | --- | --- |
| SteamWorld Dig, Linux ELF32/i386 | Native Steam → FEX (Nix) → game | Display, controls, and sound confirmed |
| SteamWorld Dig, Windows PE32/i386 | Native Steam → official ARM64 Runtime 4 → ARM64 GE-Proton with WOW64/FEX → game | Display, controls, and sound confirmed |
| Hexcells, Linux ELF64/x86-64 | Native Steam → FEX (Nix) → game | Smooth display, controls, sound, normal exit, restart, and saved progress confirmed; Adreno 830/Zink OpenGL 4.6 renderer |
| Mini Metro, Linux ELF64/x86-64 through its original Bash launcher | Native Steam → FEX (Nix) → launch script → game | Smooth display and controls, Adreno 830/Zink rendering, and a continuously updating native MangoHud overlay confirmed; no per-game graphics variables |

The two SteamWorld Dig tests cover 32-bit Linux and Windows game interaction; they did not establish those games' GPU renderer. The Hexcells test establishes a 64-bit Linux Steam launch and its hardware renderer. Mini Metro also exercises automatic graphics selection across a launch script, with the Turnip coherent-memory default enabled. These results do not establish 64-bit Windows launches from Steam or compatibility with other games.

Hexcells exited normally and was launched again through Steam. Its existing save-file hash remained unchanged across that cycle, and an in-game check confirmed that the expected level progress was retained.

Separate tests outside Steam ran official OpenTTD Linux i686, Linux x86-64, Windows i386, and Windows x86-64 binaries. All generated maps, rendered changing frames, and exited normally after a window-close request. The current Linux x86-64 FEX tool also completed a hardware-rendered session, saved on exit, and successfully reloaded that saved world. These supplementary tests do not establish in-client Steam launches for all four architectures, audible audio, physical input, or compatibility with other games.

On the tested Adreno 830 system, native ARM64 graphics and x86-64 FEX graphics both passed hardware checks: `glxinfo` reported accelerated Adreno/Zink rendering and exited normally, and `vkcube` presented ten XCB frames on the Adreno device and exited normally. This does not establish hardware acceleration for i686 Linux games; the separate 32-bit graphics paths still require validation.

## Troubleshooting {#sec-steam-troub}

- **Steam fails to start. What do I do?**

  Try to run

  ```ShellSession
  strace steam
  ```

  to see what is causing steam to fail.

- **Using the FOSS Radeon or nouveau (nvidia) drivers**

  - Steam ships statically linked with a version of `libcrypto` that conflicts with the one dynamically loaded by radeonsi_dri.so. If you get the error:

    ```
    steam.sh: line 713: 7842 Segmentation fault (core dumped)
    ```

    have a look at [this pull request](https://github.com/NixOS/nixpkgs/pull/20269).

## steam-run {#sec-steam-run}

The FHS-compatible chroot used for Steam can also be used to run other Linux games that expect a FHS environment. To use it, install the `steam-run` package and run the game with:

```
steam-run ./foo
```
