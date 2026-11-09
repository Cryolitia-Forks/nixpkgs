/*
  Evaluation coverage for Steam's native ARM64 runtime and the existing x86
  runtime. This deliberately does not download Steam, start the client, or
  claim game compatibility. Run with:

    nix-instantiate --eval --strict -A tests.steam-arm64
*/
{
  lib,
  pkgs,
  systems ? [
    "aarch64-linux"
    "x86_64-linux"
  ],
}:

let
  packageSets = lib.genAttrs systems (
    system:
    import pkgs.path {
      inherit system;
      config.allowUnfree = true;
    }
  );

  freePackageSets = lib.genAttrs systems (
    system:
    import pkgs.path {
      inherit system;
      config.allowUnfree = false;
    }
  );

  selectGtk2 =
    packages:
    lib.findFirst (
      package: lib.elem "gtk+-2.0" (package.meta.pkgConfigModules or [ ])
    ) (throw "The native ARM64 Steam FHS environment does not provide GTK2") packages;

  evaluate =
    system: audio: extraModule:
    (packageSets.${system}.nixos {
      imports = [ extraModule ];

      boot.isContainer = true;
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      system.stateVersion = lib.trivial.release;

      programs.steam = {
        enable = true;
        fontPackages = [ ];
      };

      services.pipewire = {
        enable = audio == "pipewire";
        alsa.enable = audio == "pipewire";
      };
      services.pulseaudio.enable = audio == "pulseaudio";
    }).config;

  configurations = lib.genAttrs systems (system: {
    pipewire = evaluate system "pipewire" { };
    pulseaudio = evaluate system "pulseaudio" { };
    extest = evaluate system "pipewire" { programs.steam.extest.enable = true; };
    noCompatibilityTools = evaluate system "pipewire" {
      programs.steam.extraCompatPackages = [ ];
    };
  });

  tests = lib.concatMapAttrs (
    system: configurationsForSystem:
    let
      isArm64 = system == "aarch64-linux";
      inherit (configurationsForSystem) pipewire pulseaudio extest;
      steam = pipewire.programs.steam.package;
      pkgsForSystem = packageSets.${system};
    in
    {
      "test-${system}-graphics" = {
        expr = {
          inherit (pipewire.hardware.graphics) enable enable32Bit;
          steamHardware = pipewire.hardware.steam-hardware.enable;
        };
        expected = {
          enable = true;
          enable32Bit = !isArm64;
          steamHardware = true;
        };
      };

      "test-${system}-pipewire-bitness" = {
        expr = pipewire.services.pipewire.alsa.support32Bit;
        expected = !isArm64;
      };

      "test-${system}-pulseaudio-bitness" = {
        expr = pulseaudio.services.pulseaudio.support32Bit;
        expected = !isArm64;
      };

      "test-${system}-module-assertions" = {
        expr = map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) pipewire.assertions
        );
        expected = [ ];
      };

      "test-${system}-default-compatibility-tools" = {
        expr =
          if isArm64 then
            lib.all (name: lib.elem name (map lib.getName pipewire.programs.steam.extraCompatPackages)) [
              "proton-ge-bin"
              "fex-steam"
            ]
          else
            pipewire.programs.steam.extraCompatPackages == [ ];
        expected = true;
      };

      "test-${system}-compatibility-tool-outputs" = {
        expr = lib.all (
          package: lib.isDerivation package.steamcompattool && package.system == system
        ) pipewire.programs.steam.extraCompatPackages;
        expected = true;
      };

      "test-${system}-fhs-bitness" = {
        expr = steam.args.multiArch;
        expected = !isArm64;
      };

      "test-${system}-linux-game-runtime" = {
        expr =
          !(lib.hasInfix "STEAM_COMPAT_EMULATOR=" steam.args.profile)
          && !(lib.hasInfix "STEAM_COMPAT_GRAPHICS_PROVIDER=" steam.args.profile)
          && !(lib.hasInfix "STEAM_COMPAT_EMULATOR=" steam.args.extraPreBwrapCmds)
          && !(lib.hasInfix "STEAM_COMPAT_GRAPHICS_PROVIDER=" steam.args.extraPreBwrapCmds)
          && (
            !isArm64
            || lib.all (
              package:
              let
                path = builtins.unsafeDiscardStringContext "${package.steamcompattool}";
              in
              lib.hasInfix path steam.args.extraPreBwrapCmds && !(lib.hasInfix path steam.args.profile)
            ) steam.compatPackages
          );
        expected = true;
      };

      "test-${system}-compatibility-environment-outside-fhs-profile" = {
        expr =
          let
            toolPath = builtins.unsafeDiscardStringContext "${pkgsForSystem.hello}";
            overridden = steam.override {
              extraEnv.STEAM_EXTRA_COMPAT_TOOLS_PATHS = pkgsForSystem.hello;
              extraPreBwrapCmds = "# steam-compatibility-test-pre-bwrap-hook";
            };
          in
          lib.hasInfix toolPath overridden.args.extraPreBwrapCmds
          && lib.hasInfix "steam-compatibility-test-pre-bwrap-hook" overridden.args.extraPreBwrapCmds
          && !(lib.hasInfix toolPath overridden.args.profile)
          && !(lib.hasInfix "STEAM_EXTRA_COMPAT_TOOLS_PATHS" overridden.args.profile);
        expected = true;
      };

      "test-${system}-compatibility-package-interface" = {
        expr =
          if isArm64 then
            lib.all (name: lib.elem name (map lib.getName steam.compatPackages)) [
              "proton-ge-bin"
              "fex-steam"
            ]
          else
            steam.compatPackages == [ ];
        expected = true;
      };

      # Forcing drvPath evaluates the complete FHS derivation, including the
      # runtime libraries selected by the module, without building its inputs.
      "test-${system}-steam-and-steam-run" = {
        expr =
          map
            (package: {
              inherit (package) system;
              derivationEvaluates = builtins.isString package.drvPath;
              executable = package.meta.mainProgram;
            })
            [
              steam
              steam.run
            ];
        expected = [
          {
            inherit system;
            derivationEvaluates = true;
            executable = "steam";
          }
          {
            inherit system;
            derivationEvaluates = true;
            executable = "steam-run";
          }
        ];
      };

      "test-${system}-package-overrides" = {
        expr = builtins.isString (
          (steam.override {
            extraEnv.STEAM_ARM64_EVALUATION_TEST = "1";
            extraPkgs = packages: [ packages.hello ];
            extraLibraries = packages: [ packages.libnotify ];
          }).drvPath
        );
        expected = true;
      };

      "test-${system}-extest-package-evaluates" = {
        expr = builtins.isString extest.programs.steam.package.drvPath;
        expected = true;
      };

      "test-${system}-standalone-package-evaluates" = {
        expr = builtins.isString pkgsForSystem.steam.drvPath;
        expected = true;
      };

      "test-${system}-optional-compatibility-dependencies" = {
        expr = builtins.isString (
          (pkgsForSystem.steam.override (
            {
              fex-steam = throw "Steam forced a disabled FEX compatibility dependency";
              proton-ge-bin = throw "Steam forced a disabled Proton compatibility dependency";
            }
            // lib.optionalAttrs isArm64 { compatPackages = [ ]; }
          )).drvPath
        );
        expected = true;
      };

      "test-${system}-steam-run-free" = {
        expr =
          let
            steamFree = freePackageSets.${system}.steam.override {
              fex-steam = throw "steam-run-free forced a FEX compatibility dependency";
              proton-ge-bin = throw "steam-run-free forced a Proton compatibility dependency";
            };
          in
          builtins.isString steamFree.run-free.drvPath
          && !(lib.hasInfix "STEAM_EXTRA_COMPAT_TOOLS_PATHS=" steamFree.run-free.args.profile)
          && !(lib.hasInfix "STEAM_EXTRA_COMPAT_TOOLS_PATHS=" steamFree.run-free.args.extraPreBwrapCmds)
          && !(lib.hasInfix "STEAM_COMPAT_EMULATOR=" steamFree.run-free.args.profile)
          && !(lib.hasInfix "STEAM_COMPAT_GRAPHICS_PROVIDER=" steamFree.run-free.args.profile);
        expected = true;
      };
    }
    // lib.optionalAttrs isArm64 {
      test-arm64-native-gtk2 = {
        expr =
          let
            gtk2 = selectGtk2 (steam.args.multiPkgs pkgsForSystem);
          in
          gtk2.system == system
          && !(gtk2.meta.problems ? broken)
          && lib.elem "https://github.com/NixOS/nixpkgs/issues/410814" (
            pkgsForSystem.gtk2.meta.problems.broken.urls or [ ]
          )
          && !(pkgsForSystem.config.allowBroken or false);
        expected = true;
      };

      test-arm64-gtk2-preserves-other-problems = {
        expr =
          let
            gtk2WithOtherProblems = pkgsForSystem.gtk2.overrideAttrs (previous: {
              meta = previous.meta // {
                knownVulnerabilities = [ "Steam evaluation test vulnerability" ];
                problems = (previous.meta.problems or { }) // {
                  steamTestOtherFailure = {
                    kind = "broken";
                    message = "An unrelated GTK2 build failure must remain visible";
                    urls = [ "https://example.invalid/steam-gtk2-build-failure" ];
                  };
                };
              };
            });
            gtk2 = selectGtk2 (
              steam.args.multiPkgs (pkgsForSystem.extend (_: _: { gtk2 = gtk2WithOtherProblems; }))
            );
          in
          gtk2.meta.knownVulnerabilities == [ "Steam evaluation test vulnerability" ]
          &&
            gtk2.meta.problems.steamTestOtherFailure.message
            == "An unrelated GTK2 build failure must remain visible"
          && !(gtk2.meta.problems ? broken);
        expected = true;
      };

      test-arm64-gtk2-preserves-different-broken-problem = {
        expr =
          let
            gtk2WithBuildFailure = pkgsForSystem.gtk2.overrideAttrs (previous: {
              meta = previous.meta // {
                problems = (previous.meta.problems or { }) // {
                  broken = {
                    message = "This GTK2 build is broken for a different reason";
                    urls = [ "https://example.invalid/steam-gtk2-other-broken" ];
                  };
                };
              };
            });
            gtk2 = selectGtk2 (
              steam.args.multiPkgs (pkgsForSystem.extend (_: _: { gtk2 = gtk2WithBuildFailure; }))
            );
          in
          gtk2.meta.problems.broken.message == "This GTK2 build is broken for a different reason";
        expected = true;
      };

      test-arm64-fex-runtime-description = {
        expr =
          let
            fex = pkgsForSystem.fex-steam;
          in
          fex.emulatorDescription == "${fex.steamcompattool}/emulator.json"
          && fex.graphicsProvider == "${fex.rootfs}/graphics-provider.json"
          && lib.isDerivation fex.rootfs;
        expected = true;
      };

      test-arm64-disable-default-compatibility-tools = {
        expr =
          let
            configuration = configurationsForSystem.noCompatibilityTools;
          in
          configuration.programs.steam.extraCompatPackages == [ ]
          && configuration.programs.steam.package.compatPackages == [ ]
          && lib.hasInfix "STEAM_EXTRA_COMPAT_TOOLS_PATHS=''" (
            configuration.programs.steam.package.args.extraPreBwrapCmds
          );
        expected = true;
      };
    }
  ) configurations;
in
lib.debug.throwTestFailures {
  failures = lib.runTests tests;
  description = "Steam ARM64 and x86 module evaluation tests";
}
