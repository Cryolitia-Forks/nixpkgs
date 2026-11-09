"""Check the actual portable ELF depot, not a mocked launcher invocation."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import struct
import subprocess


def machine(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    assert header[:4] == b"\x7fELF" and header[5] == 1, path
    return struct.unpack_from("<H", header, 18)[0]


def patchelf(option, path):
    return subprocess.check_output(["patchelf", option, str(path)], text=True).strip()


def read_vdf(path):
    tokens = iter(shlex.split(path.read_text()))

    def object_(nested=False):
        result = {}
        for key in tokens:
            if key == "}":
                assert nested, path
                return result
            assert key != "{", (path, key)
            value = next(tokens)
            assert value != "}", (path, key)
            assert key not in result, (path, key)
            result[key] = object_(True) if value == "{" else value
        assert not nested, path
        return result

    return object_()


def check(depot, source):
    registration = read_vdf(depot / "compatibilitytool.vdf")
    tools = registration["compatibilitytools"]["compat_tools"]
    assert set(tools) == {"fex-nix"}, registration
    tool = tools["fex-nix"]
    assert tool["install_path"] == ".", tool
    assert tool["from_oslist"] == tool["to_oslist"] == "linux", tool
    manifest = read_vdf(depot / "toolmanifest.vdf")["manifest"]
    assert manifest["version"] == "2", manifest
    assert manifest["commandline"] == "/fex-steam-launch %verb% --", manifest
    assert manifest["compatmanager_layer_name"] == "fex", manifest
    assert (depot / "fex-steam-launch").is_file()
    libdir = depot / "usr/lib/aarch64-linux-gnu"
    loader = libdir / "ld-linux-aarch64.so.1"
    assert machine(loader) == 183
    original_loader = Path(patchelf("--print-interpreter", source / "bin/FEX"))
    assert hashlib.sha256(loader.read_bytes()).digest() == hashlib.sha256(original_loader.read_bytes()).digest()
    entries = [depot / "FEXCompatTool"] + [
        depot / "usr/bin" / name for name in ("FEX", "FEXServer", "FEXServerManager")
    ]
    for entry in entries:
        assert machine(entry) == 183, entry
        assert patchelf("--print-interpreter", entry) == str(loader), entry

    libraries = list(libdir.glob("*.so*")) + list((libdir / "fex-emu").rglob("*.so"))
    for binary in entries + libraries:
        assert machine(binary) == 183, binary
        needed = patchelf("--print-needed", binary).splitlines()
        for name in needed:
            dependency = libdir / name
            assert dependency.is_file(), (binary, name)
            assert machine(dependency) == 183, dependency
        if binary == loader:
            continue
        dynamic = subprocess.check_output(["readelf", "-dW", str(binary)], text=True)
        assert "(RPATH)" in dynamic and "(RUNPATH)" not in dynamic, binary
        paths = patchelf("--print-rpath", binary).replace("${ORIGIN}", str(binary.parent))
        paths = paths.replace("$ORIGIN", str(binary.parent)).split(":")
        assert libdir in [Path(path).resolve() for path in paths], (binary, paths)
        for path in paths:
            assert Path(path).resolve().is_relative_to(depot), (binary, path)

    for suffix, expected in (("", 62), ("_32", 3)):
        guests = list((depot / f"usr/share/fex-emu/GuestThunks{suffix}").glob("*.so"))
        hosts = list((libdir / f"fex-emu/HostThunks{suffix}").glob("*.so"))
        assert guests and hosts, suffix
        assert all(machine(path) == expected for path in guests), suffix
        assert all(machine(path) == 183 for path in hosts), suffix
        for guest in guests:
            if guest.name == "libVDSO-guest.so":
                original = source / f"share/fex-emu/GuestThunks{suffix}" / guest.name
                assert guest.read_bytes() == original.read_bytes(), guest
                continue
            assert {"libstdc++.so.6", "libgcc_s.so.1"}.issubset(patchelf("--print-needed", guest).splitlines()), guest
            dynamic = subprocess.check_output(["readelf", "-dW", str(guest)], text=True)
            assert any("(FLAGS_1)" in line and "NODELETE" in line for line in dynamic.splitlines()), guest

    emulator = json.loads((depot / "emulator.json").read_text())["emulator_v0"]
    assert set(emulator["emulated_architectures"]) == {"x86_64-linux-gnu", "i386-linux-gnu"}
    assert emulator["required_architectures"] == ["aarch64-linux-gnu"]
    assert emulator["container_environment"]["FEX_ROOTFS"] == ""
    for key in ("argv", "container_argv", "main_argv", "server_argv"):
        path = emulator[key]
        if isinstance(path, list):
            path = path[0]
        assert machine((depot / path).resolve()) == 183, (key, path)
    config = json.loads((depot / "ConfigTemplate.json").read_text())
    assert config["ThunksDB"]["Vulkan"] == "1"
    print(f"Validated {len(entries)} ARM64 entry points and {len(libraries)} native libraries")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--depot", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    check(args.depot, args.source)
