{ lib, gtk2 }:

# Valve's ARM64 steamui.so still has a DT_NEEDED entry for
# libgtk-x11-2.0.so.0. GTK3 does not implement that ABI. Keep this dependency
# private to Steam: GTK2's current broken marker announces its planned removal,
# rather than a build failure, and cannot be resolved in a closed-source client
# by migrating the Nix launcher. Do not suppress unrelated or future problems.
gtk2.overrideAttrs (previous: {
  meta = previous.meta // {
    problems = lib.filterAttrs (
      name: problem:
      name != "broken"
      || !(lib.elem "https://github.com/NixOS/nixpkgs/issues/410814" (problem.urls or [ ]))
    ) (previous.meta.problems or { });
  };
})
