#!@python@
"""Steam entry point; CPU emulation is scoped to the selected Linux game."""

import json
import os
from pathlib import Path
import struct
import sys
import tempfile

ROOTFS = "@rootfs@"
DRIVER_OPTIONS = ("MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "LIBGL_KOPPER_DISABLE")
AUTO_ZINK = "FEX_NIX_AUTO_GUEST_ZINK"
AUTO_ZINK_MARKERS = (AUTO_ZINK, AUTO_ZINK + "_ROOTFS", AUTO_ZINK + "_APP_CONFIG")


def fex_object(pairs):
    result = {}
    for name, value in pairs:
        if name in ("Env", "HostEnv"):
            result.setdefault(name, []).extend(value if isinstance(value, list) else [value])
        else:
            result[name] = value
    return result


def fex_json(template):
    # FEX's own SaveLayerToJSON emits one repeated string key per strarray
    # entry. Its tiny-json reader does not accept a JSON array for Config.Env.
    config = []
    for name, value in template["Config"].items():
        values = value if name in ("Env", "HostEnv") and isinstance(value, list) else [value]
        config.extend(json.dumps(name) + ": " + json.dumps(item) for item in values)
    config = "{" + ", ".join(config) + "}"
    return "{" + ", ".join(
        json.dumps(name) + ": " + (config if name == "Config" else json.dumps(value))
        for name, value in template.items()
    ) + "}\n"


def guest_graphics_template(tool_root, environment):
    """Keep native thunk drivers separate from an uncontainerized x86 Mesa."""
    # A nested launch can inherit our transport markers. Reevaluate its actual
    # RootFS and expert settings instead of carrying over the previous policy.
    for name in AUTO_ZINK_MARKERS:
        environment.pop(name, None)
    if environment["FEX_ROOTFS"] != ROOTFS or environment.get("FEX_STEAM_CONFIG_TEMPLATE"):
        return
    template = json.loads((tool_root / "ConfigTemplate.json").read_text(), object_pairs_hook=fex_object)
    rootfs = Path(ROOTFS)
    graphics = {
        "LIBGL_DRIVERS_PATH": "/usr/lib64/dri:/usr/lib32/dri",
        "__EGL_VENDOR_LIBRARY_DIRS": "/usr/share/glvnd/egl_vendor.d",
        "LIBVA_DRIVERS_PATH": "/usr/lib64/dri:/usr/lib32/dri",
        "GBM_BACKENDS_PATH": "/usr/lib64/gbm:/usr/lib32/gbm",
        "__GLX_VENDOR_LIBRARY_NAME": "mesa",
    }
    # FEX chooses guest defaults after reading each actual ELF. In particular,
    # a 64-bit shell must not pass its Zink defaults into a 32-bit child.
    explicit_guest_option = environment.get("FEX_ENV", "").partition("=")[0]
    auto_zink = (
        "ThunksDB_Vulkan:1" in environment.get("STEAM_COMPAT_FEX_CONFIG", "")
        and "FEX_APP_CONFIG" not in environment
        and explicit_guest_option not in DRIVER_OPTIONS
    )
    if auto_zink:
        environment[AUTO_ZINK] = "1"
        environment[AUTO_ZINK + "_ROOTFS"] = ROOTFS
        environment[AUTO_ZINK + "_APP_CONFIG"] = str(
            Path(environment["STEAM_COMPAT_DATA_PATH"]) / "fex-emu/app_config.json"
        )
    # Explicit filename variables take precedence over directory searches.
    # Keep both ABIs; each guest loader skips the other ELF class.
    for variable, directory in (
        ("__EGL_VENDOR_LIBRARY_FILENAMES", "usr/share/glvnd/egl_vendor.d"),
        ("VK_DRIVER_FILES", "usr/share/vulkan/icd.d"),
    ):
        manifests = sorted((rootfs / directory).glob("*.json"))
        if manifests:
            graphics[variable] = ":".join("/" + str(path.relative_to(rootfs)) for path in manifests)
    if "VK_DRIVER_FILES" in graphics:
        graphics["VK_ICD_FILENAMES"] = graphics["VK_DRIVER_FILES"]
        graphics["VK_ADD_DRIVER_FILES"] = ""
    config = template.setdefault("Config", {})
    config["Env"] = [
        *config.get("Env", []), *(f"{name}={value}" for name, value in graphics.items()),
    ]
    # A guest shell passes its environment back to FEX when it execs another
    # program. Restore the native graphics settings before loading host thunks;
    # otherwise the native Vulkan loader sees the guest's x86 ICD manifests.
    # FEX applies HostEnv through glibc putenv: a bare name unsets the variable,
    # while NAME= preserves an explicitly empty value.
    host_graphics = list(graphics) + (list(DRIVER_OPTIONS) if auto_zink else [])
    config["HostEnv"] = [
        *config.get("HostEnv", []),
        *(f"{name}={environment[name]}" if name in environment else name for name in host_graphics),
    ]
    directory = Path(environment["STEAM_COMPAT_DATA_PATH"]) / "fex-nix"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "ConfigTemplate.json"
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as stream:
        stream.write(fex_json(template))
        temporary = stream.name
    os.replace(temporary, target)
    environment["FEX_STEAM_CONFIG_TEMPLATE"] = str(target)


def elf_machine(path):
    try:
        with open(path, "rb") as stream:
            header = stream.read(20)
    except OSError:
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[5] != 1:
        return None
    return struct.unpack_from("<H", header, 18)[0]


def launch(arguments, tool_root, environment):
    for name in AUTO_ZINK_MARKERS:
        environment.pop(name, None)
    arguments = list(arguments)
    if arguments and arguments[0] in ("run", "waitforexitandrun"):
        arguments.pop(0)
    elif arguments and arguments[0] in ("getcompatpath", "getnativepath"):
        arguments.pop(0)
        if arguments and arguments[0] == "--":
            arguments.pop(0)
        if arguments:
            print(arguments[0])
        return 0
    if arguments and arguments[0] == "--":
        arguments.pop(0)
    if not arguments:
        print("Usage: fex-steam [waitforexitandrun --] PROGRAM [ARGUMENT...]", file=sys.stderr)
        return 2

    command = Path(arguments[0])
    is_container_setup = command.name in ("_v2-entry-point", "_entry-point", "pressure-vessel-wrap")
    machine = elf_machine(arguments[0])

    # The Steam client does not document from_arch/to_arch fields for custom
    # tools. Protect a native ARM64 game if this Linux-to-Linux tool is selected.
    if not is_container_setup and machine == 183:
        environment.pop("STEAM_COMPAT_EMULATOR", None)
        environment.pop("STEAM_COMPAT_GRAPHICS_PROVIDER", None)
        os.execvpe(arguments[0], arguments, environment)

    environment.setdefault("STEAM_COMPAT_EMULATOR", str(tool_root / "emulator.json"))
    environment.setdefault("STEAM_COMPAT_GRAPHICS_PROVIDER", str(Path(ROOTFS) / "graphics-provider.json"))
    environment.setdefault("STEAM_COMPAT_MACHINE_ARCHITECTURE", "aarch64-linux-gnu")
    environment.setdefault("FEX_PORTABLE", "1")
    # .NET dual-mapped JIT code can fault under FEX. Preserve explicit
    # runtime settings and guest configuration overrides.
    wx_options = ("DOTNET_EnableWriteXorExecute", "COMPlus_EnableWriteXorExecute")
    if (
        "COMPlus_EnableWriteXorExecute" not in environment
        and "FEX_APP_CONFIG" not in environment
        and "FEX_STEAM_CONFIG_TEMPLATE" not in environment
        and environment.get("FEX_ENV", "").partition("=")[0] not in wx_options
    ):
        environment.setdefault("DOTNET_EnableWriteXorExecute", "0")
    # Match Valve's FEX wrapper. Atomic x86 memory accesses to uncached GPU
    # buffers can be prohibitively slow on coherent UMA Turnip devices.
    environment.setdefault("tu_override_uncached_as_cache_coherent", "true")
    # Steam can provide an empty or unrelated FEX options string. The upstream
    # helper interprets a missing Vulkan token as off, overriding our template.
    # Supply the Nix default while retaining an explicit selection or an expert
    # app configuration and preserving the other Steam options.
    if "FEX_APP_CONFIG" not in environment:
        options = environment.get("STEAM_COMPAT_FEX_CONFIG", "")
        if "ThunksDB_Vulkan:" not in options:
            environment["STEAM_COMPAT_FEX_CONFIG"] = (
                options + ("," if options else "") + "ThunksDB_Vulkan:1"
            )
    # The empty string is significant inside a pressure-vessel container: the
    # container already supplies the x86 filesystem. Never overwrite it.
    environment.setdefault("FEX_ROOTFS", ROOTFS)
    if not environment.get("STEAM_COMPAT_DATA_PATH"):
        cache_home = Path(environment.get("XDG_CACHE_HOME") or str(Path.home() / ".cache"))
        if not cache_home.is_absolute():
            cache_home = Path.home() / ".cache"
        app_id = environment.get("STEAM_COMPAT_APP_ID") or environment.get("SteamAppId") or "0"
        if not (app_id.isascii() and app_id.isdecimal()):
            app_id = "0"
        environment["STEAM_COMPAT_DATA_PATH"] = str(cache_home / "fex-steam" / app_id)
    Path(environment["STEAM_COMPAT_DATA_PATH"]).mkdir(parents=True, exist_ok=True)

    # A pre-existing Steam Linux Runtime command needs the emulator during
    # container setup, not just around its eventual game executable.
    if is_container_setup:
        os.execvpe(arguments[0], arguments, environment)
    guest_graphics_template(tool_root, environment)
    interpreter = str(tool_root / "FEXCompatTool")
    os.execve(interpreter, [interpreter, *arguments], environment)


if __name__ == "__main__":
    sys.exit(launch(sys.argv[1:], Path(__file__).resolve().parent, dict(os.environ)))
