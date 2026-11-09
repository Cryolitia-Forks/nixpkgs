// SPDX-License-Identifier: MIT
#include "steam-guest-graphics.h"

#include <array>
#include <cassert>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

using Environment = std::vector<std::string>;
constexpr std::array<const char*, 3> Names {
  "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "LIBGL_KOPPER_DISABLE",
};

static std::optional<std::string> Native(const char* Name) {
  const char* Value = std::getenv(Name);
  return Value ? std::optional<std::string> {Value} : std::nullopt;
}

static auto Snapshot() {
  return std::array {Native(Names[0]), Native(Names[1]), Native(Names[2]),
                     Native("FEX_NIX_AUTO_GUEST_ZINK"), Native("FEX_NIX_AUTO_GUEST_ZINK_ROOTFS"),
                     Native("FEX_ROOTFS"), Native("FEX_NIX_AUTO_GUEST_ZINK_APP_CONFIG"),
                     Native("FEX_APP_CONFIG"), Native("FEX_ENV"), Native("STEAM_COMPAT_FEX_CONFIG")};
}

static void Configure(Environment& Variables, bool Is64Bit, const Environment& Additional = {}) {
  const auto Before = Snapshot();
  const auto OriginalAdditional = Additional;
  // Match ELFCodeLoader: effective Config.Env is appended before the helper.
  Variables.insert(Variables.end(), Additional.begin(), Additional.end());
  FEX::Nix::ConfigureGuestGraphics(Variables, Is64Bit, Additional);
  assert(Snapshot() == Before);
  assert(Additional == OriginalAdditional);
}

static const Environment Unrelated {
  "DISPLAY=:0", "GALLIUM_DRIVER_EXTRA=keep", "PREFIX_GALLIUM_DRIVER=keep",
  "MESA_LOADER_DRIVER_OVERRIDE_SUFFIX=keep", "LIBGL_KOPPER_DISABLE_EXTRA=keep",
  "OTHER=GALLIUM_DRIVER=keep",
};

static Environment Polluted() {
  Environment Variables = Unrelated;
  Variables.insert(Variables.end(), {
    "MESA_LOADER_DRIVER_OVERRIDE=old-a", "MESA_LOADER_DRIVER_OVERRIDE=old-b",
    "GALLIUM_DRIVER=old-a", "GALLIUM_DRIVER", "GALLIUM_DRIVER=old-b",
    "LIBGL_KOPPER_DISABLE=old-a", "LIBGL_KOPPER_DISABLE=old-b",
  });
  return Variables;
}

static Environment Zink() {
  Environment Variables = Unrelated;
  Variables.insert(Variables.end(), {
    "MESA_LOADER_DRIVER_OVERRIDE=zink", "GALLIUM_DRIVER=zink", "LIBGL_KOPPER_DISABLE=0",
  });
  return Variables;
}

static Environment NativeGuest() {
  Environment Variables = Unrelated;
  for (const char* Name : Names) {
    if (const auto Value = Native(Name)) {
      Variables.emplace_back(std::string {Name} + "=" + *Value);
    }
  }
  return Variables;
}

static void SetMarkers() {
  assert(setenv("FEX_NIX_AUTO_GUEST_ZINK_ROOTFS", "/nix/store/test-rootfs", 1) == 0);
  assert(setenv("FEX_ROOTFS", "/nix/store/test-rootfs", 1) == 0);
  assert(setenv("FEX_NIX_AUTO_GUEST_ZINK_APP_CONFIG", "/data/fex-emu/app_config.json", 1) == 0);
  assert(setenv("FEX_APP_CONFIG", "/data/fex-emu/app_config.json", 1) == 0);
}

static Environment ExplicitGuest(const char* OverrideName, const std::string& OverrideValue) {
  Environment Variables = Unrelated;
  for (const char* Name : Names) {
    if (std::strcmp(Name, OverrideName) == 0) {
      Variables.emplace_back(std::string {Name} + "=" + OverrideValue);
    } else if (const auto Value = Native(Name)) {
      Variables.emplace_back(std::string {Name} + "=" + *Value);
    }
  }
  return Variables;
}

int main() {
  assert(unsetenv("FEX_ENV") == 0);
  assert(unsetenv("STEAM_COMPAT_FEX_CONFIG") == 0);
  SetMarkers();
  assert(setenv(Names[0], "native=value", 1) == 0);
  assert(setenv(Names[1], "", 1) == 0);
  assert(unsetenv(Names[2]) == 0);

  for (const char* Enabled : std::array<const char*, 4> {nullptr, "0", "01", "true"}) {
    if (Enabled) {
      assert(setenv("FEX_NIX_AUTO_GUEST_ZINK", Enabled, 1) == 0);
    } else {
      assert(unsetenv("FEX_NIX_AUTO_GUEST_ZINK") == 0);
    }
    for (bool Is64Bit : {false, true}) {
      auto Variables = Polluted();
      const auto Expected = Variables;
      Configure(Variables, Is64Bit);
      assert(Variables == Expected);
    }
  }

  assert(setenv("FEX_NIX_AUTO_GUEST_ZINK", "1", 1) == 0);
  SetMarkers();
  // Missing or empty trusted metadata cannot identify inherited defaults.
  for (const char* Name : {"FEX_NIX_AUTO_GUEST_ZINK_ROOTFS", "FEX_NIX_AUTO_GUEST_ZINK_APP_CONFIG"}) {
    for (bool Missing : {false, true}) {
      if (Missing) {
        assert(unsetenv(Name) == 0);
      } else {
        assert(setenv(Name, "", 1) == 0);
      }
      for (bool Is64Bit : {false, true}) {
        auto Variables = Polluted();
        const auto Expected = Variables;
        Configure(Variables, Is64Bit);
        assert(Variables == Expected);
      }
      SetMarkers();
    }
  }
  // A descendant with different actual scope discards inherited defaults.
  for (const char* Name : {"FEX_ROOTFS", "FEX_APP_CONFIG"}) {
    for (const char* Value : std::array<const char*, 3> {nullptr, "", "/custom/override"}) {
      if (Value) {
        assert(setenv(Name, Value, 1) == 0);
      } else {
        assert(unsetenv(Name) == 0);
      }
      for (bool Is64Bit : {false, true}) {
        auto Variables = Zink();
        Configure(Variables, Is64Bit);
        assert(Variables == NativeGuest());
      }
      SetMarkers();
    }
  }
  for (const char* Name : {"FEX_NIX_AUTO_GUEST_ZINK_ROOTFS", "FEX_NIX_AUTO_GUEST_ZINK_APP_CONFIG"}) {
    assert(setenv(Name, "/different/expected-scope", 1) == 0);
    auto Variables = Zink();
    Configure(Variables, true);
    assert(Variables == NativeGuest());
    SetMarkers();
  }
  // Rotate unset, empty and nonempty native values through every driver key.
  for (size_t Offset = 0; Offset != Names.size(); ++Offset) {
    assert(setenv(Names[Offset], "native=value", 1) == 0);
    assert(setenv(Names[(Offset + 1) % Names.size()], "", 1) == 0);
    assert(unsetenv(Names[(Offset + 2) % Names.size()]) == 0);

    auto Variables = Polluted();
    Configure(Variables, true);
    assert(Variables == Zink());
    Configure(Variables, false);
    assert(Variables == NativeGuest());
    Configure(Variables, true);
    assert(Variables == Zink());

    Variables = Polluted();
    Configure(Variables, false);
    assert(Variables == NativeGuest());
    Configure(Variables, false);
    assert(Variables == NativeGuest());
  }

  assert(setenv(Names[0], "native=value", 1) == 0);
  assert(setenv(Names[1], "", 1) == 0);
  assert(unsetenv(Names[2]) == 0);
  // Effective Config.Env overrides must beat inherited parent defaults.
  // This covers both app JSON Env entries and entries loaded from FEX_ENV.
  for (const char* Name : Names) {
    for (const std::string Value : {"", "custom=value"}) {
      const auto Setting = std::string {Name} + "=" + Value;
      for (bool Is64Bit : {false, true}) {
        auto Variables = Zink();
        Configure(Variables, Is64Bit, {Setting});
        assert(Variables == ExplicitGuest(Name, Value));
      }
    }
  }
  auto Variables = Polluted();
  Configure(Variables, true);
  assert(Variables == Zink());
  assert(setenv("FEX_APP_CONFIG", "/custom/app.json", 1) == 0);
  Configure(Variables, true, {"GALLIUM_DRIVER=llvmpipe"});
  assert(Variables == ExplicitGuest("GALLIUM_DRIVER", "llvmpipe"));
  SetMarkers();

  // Multiple explicit keys retain their final assignments without duplicates.
  Variables = Zink();
  Configure(Variables, true, {"GALLIUM_DRIVER=earlier", "MESA_LOADER_DRIVER_OVERRIDE=earlier",
                             "GALLIUM_DRIVER=last=value", "MESA_LOADER_DRIVER_OVERRIDE="});
  auto Expected = Unrelated;
  Expected.emplace_back("MESA_LOADER_DRIVER_OVERRIDE=");
  Expected.emplace_back("GALLIUM_DRIVER=last=value");
  assert(Variables == Expected);

  // An unrelated prefix is not an explicit override of a managed driver key.
  Variables = Polluted();
  Configure(Variables, true, {"GALLIUM_DRIVER_EXTRA=custom"});
  Expected = Zink();
  Expected.insert(Expected.begin() + Unrelated.size(), "GALLIUM_DRIVER_EXTRA=custom");
  assert(Variables == Expected);

  // A child disabling Vulkan must discard the parent's automatic Zink values.
  Variables = Zink();
  assert(setenv("STEAM_COMPAT_FEX_CONFIG", "TSOEnabled:1,ThunksDB_Vulkan:0", 1) == 0);
  Configure(Variables, true);
  assert(Variables == NativeGuest());
  Configure(Variables, false);
  assert(Variables == NativeGuest());
  assert(setenv("STEAM_COMPAT_FEX_CONFIG", "ThunksDB_Vulkan:1", 1) == 0);
  Configure(Variables, true);
  assert(Variables == Zink());

  std::cout << "Guest graphics helper: opt-in, ELF64, mixed-bitness exec, native unset/empty/value, "
               "root/config guards, descendant driver/Vulkan overrides, duplicate keys, exact matching "
               "and unchanged native environment all passed.\n";
}
