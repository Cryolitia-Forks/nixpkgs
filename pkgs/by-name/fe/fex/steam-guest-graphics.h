// SPDX-License-Identifier: MIT
#pragma once

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string_view>
#include <utility>

namespace FEX::Nix {
template<typename Environment, typename AdditionalEnvironment>
inline void ConfigureGuestGraphics(Environment& Variables, bool Is64Bit, const AdditionalEnvironment& Additional) {
  const char* Enabled = std::getenv("FEX_NIX_AUTO_GUEST_ZINK");
  if (!Enabled || std::strcmp(Enabled, "1") != 0) {
    return;
  }
  const char* ExpectedRoot = std::getenv("FEX_NIX_AUTO_GUEST_ZINK_ROOTFS");
  const char* ExpectedApp = std::getenv("FEX_NIX_AUTO_GUEST_ZINK_APP_CONFIG");
  if (!ExpectedRoot || !*ExpectedRoot || !ExpectedApp || !*ExpectedApp) {
    return;
  }
  const auto MatchesEnvironment = [](const char* Expected, const char* ActualName) {
    const char* Actual = std::getenv(ActualName);
    return Actual && std::strcmp(Expected, Actual) == 0;
  };
  const bool MatchesScope = MatchesEnvironment(ExpectedRoot, "FEX_ROOTFS") &&
                            MatchesEnvironment(ExpectedApp, "FEX_APP_CONFIG");

  constexpr const char* Names[] = {
    "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "LIBGL_KOPPER_DISABLE",
  };
  constexpr const char* Defaults[] = {
    "MESA_LOADER_DRIVER_OVERRIDE=zink", "GALLIUM_DRIVER=zink", "LIBGL_KOPPER_DISABLE=0",
  };

  // Effective Config.Env includes app configuration and environment overrides.
  // Retain the last explicit assignment to each driver, including empty values.
  using String = typename Environment::value_type;
  std::optional<String> Overrides[3];
  bool HasOverrides = false;
  for (const auto& Entry : Additional) {
    const std::string_view Value {Entry.data(), Entry.size()};
    const auto Separator = Value.find('=');
    if (Separator == std::string_view::npos) {
      continue;
    }
    for (size_t Index = 0; Index != 3; ++Index) {
      if (Value.substr(0, Separator) == Names[Index]) {
        Overrides[Index] = String {Entry.data() + Separator + 1, Entry.size() - Separator - 1};
        HasOverrides = true;
      }
    }
  }
  const char* Options = std::getenv("STEAM_COMPAT_FEX_CONFIG");
  const bool VulkanDisabled = Options && std::strstr(Options, "ThunksDB_Vulkan:0");

  // An emulated shell can exec a game of a different bitness. Remove every
  // inherited copy before choosing settings for the ELF actually being loaded.
  Variables.erase(std::remove_if(Variables.begin(), Variables.end(), [&](const auto& Entry) {
    const std::string_view Value {Entry.data(), Entry.size()};
    const auto Name = Value.substr(0, Value.find('='));
    for (const char* GraphicsName : Names) {
      if (Name == GraphicsName) {
        return true;
      }
    }
    return false;
  }), Variables.end());

  if (MatchesScope && Is64Bit && !HasOverrides && !VulkanDisabled) {
    for (const char* Default : Defaults) {
      Variables.emplace_back(Default);
    }
  } else {
    // Config.HostEnv has restored the original native values. Read them
    // explicitly rather than relying on putenv mutating the original envp.
    for (size_t Index = 0; Index != 3; ++Index) {
      const char* Name = Names[Index];
      const char* Value = Overrides[Index] ? Overrides[Index]->c_str() : std::getenv(Name);
      if (Value) {
        typename Environment::value_type Entry {Name};
        Entry += '=';
        Entry += Value;
        Variables.emplace_back(std::move(Entry));
      }
    }
  }
}
} // namespace FEX::Nix
