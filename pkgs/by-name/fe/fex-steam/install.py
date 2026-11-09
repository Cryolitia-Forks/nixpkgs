"""Make the upstream Steam-mode FEX build a self-contained portable depot."""

import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess


def elf_machine(path):
    try:
        with path.open("rb") as stream:
            header = stream.read(20)
    except OSError:
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[5] != 1:
        return None
    return struct.unpack_from("<H", header, 18)[0]


def patch(path, runpath, interpreter=None):
    path.chmod(path.stat().st_mode | 0o200)
    # Steam and games commonly set LD_LIBRARY_PATH to their own runtime. That
    # must not mix an older libc/libm with this depot's matching private loader.
    subprocess.run(["patchelf", "--force-rpath", "--set-rpath", runpath, str(path)], check=True)
    if interpreter is not None:
        subprocess.run([
            "patchelf", "--set-interpreter", str(interpreter), str(path),
        ], check=True)


def library_aliases(rootfs, path):
    """Include the SONAME alias as well as the final versioned Nix file."""
    seen = set()
    while path not in seen:
        path.relative_to(rootfs)
        seen.add(path)
        yield path
        if not path.is_symlink():
            break
        path = Path(os.path.normpath(path.parent / path.readlink()))
    final = path.resolve(strict=True)
    final.relative_to(rootfs)
    if final not in seen:
        yield final


def mark_nodelete(path):
    # FEX and C++ exit handlers can retain guest function pointers after a
    # caller's dlclose. Preserve the thunk image until process exit. Updating
    # the existing tag leaves its ELF layout and relocations unchanged.
    data = bytearray(path.read_bytes())
    if len(data) < 16 or data[:4] != b"\x7fELF" or data[5] != 1:
        raise ValueError(f"Expected little-endian guest ELF: {path}")
    if data[4] == 2:
        if len(data) < 64:
            raise ValueError(f"Truncated ELF64 header: {path}")
        minimum_header, minimum_phdr = 64, 56
        phoff = struct.unpack_from("<Q", data, 32)[0]
        phsize, phcount = struct.unpack_from("<HH", data, 54)
        phformat, offset_index, size_index = "<IIQQQQQQ", 2, 5
        dynamic_format, wordsize = "<QQ", 8
    elif data[4] == 1:
        if len(data) < 52:
            raise ValueError(f"Truncated ELF32 header: {path}")
        minimum_header, minimum_phdr = 52, 32
        phoff = struct.unpack_from("<I", data, 28)[0]
        phsize, phcount = struct.unpack_from("<HH", data, 42)
        phformat, offset_index, size_index = "<IIIIIIII", 1, 4
        dynamic_format, wordsize = "<II", 4
    else:
        raise ValueError(f"Unsupported ELF class: {path}")
    if phsize < minimum_phdr or phoff < minimum_header or phoff + phcount * phsize > len(data):
        raise ValueError(f"Invalid program header table bounds: {path}")
    dynamic_headers = []
    for index in range(phcount):
        header = struct.unpack_from(phformat, data, phoff + index * phsize)
        if header[0] == 2:  # PT_DYNAMIC
            dynamic_headers.append(header)
    if len(dynamic_headers) != 1:
        raise ValueError(f"Expected one PT_DYNAMIC segment: {path}")
    header = dynamic_headers[0]
    start, size = header[offset_index], header[size_index]
    if size % (2 * wordsize) or start + size > len(data):
        raise ValueError(f"Invalid dynamic segment bounds: {path}")
    for offset in range(start, start + size, 2 * wordsize):
        tag, value = struct.unpack_from(dynamic_format, data, offset)
        if tag == 0:
            break
        if tag == 0x6FFFFFFB:  # DT_FLAGS_1, present with Nix's BIND_NOW
            struct.pack_into("<Q" if wordsize == 8 else "<I", data, offset + wordsize, value | 8)
            path.write_bytes(data)
            return
    raise ValueError(f"Guest library has no DT_FLAGS_1 entry: {path}")


def install(source, destination, closure, rootfs):
    bindir = destination / "usr/bin"
    libdir = destination / "usr/lib/aarch64-linux-gnu"
    bindir.mkdir(parents=True)
    libdir.mkdir(parents=True)
    # pressure-vessel automatically shares the emulator manifest's parent.
    # Put PT_INTERP in that same output so the loader always matches our libc,
    # even when the container's own glibc is older than Nixpkgs'.
    interpreter = libdir / "ld-linux-aarch64.so.1"
    # /proc/self/exe determines FEX's portable root. Copy executable files:
    # symlinks back into the non-portable build would select the wrong directory.
    shutil.copy2(source / "FEXCompatTool", destination / "FEXCompatTool")
    patch(destination / "FEXCompatTool", "$ORIGIN/usr/lib/aarch64-linux-gnu", interpreter)
    for name in ("FEX", "FEXServer", "FEXServerManager"):
        shutil.copy2(source / "bin" / name, bindir / name)
        patch(bindir / name, "$ORIGIN/../lib/aarch64-linux-gnu", interpreter)
    for package in (Path(path) for path in closure.read_text().splitlines()):
        directory = package / "lib"
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if ".so" not in path.name or not path.is_file() or elf_machine(path) != 183:
                continue
            target = libdir / path.name
            if not target.exists():
                shutil.copy2(path.resolve(), target)
                if path.name != "ld-linux-aarch64.so.1":
                    patch(target, "$ORIGIN")
    host_thunks = libdir / "fex-emu/HostThunks"
    guest_thunks = destination / "usr/share/fex-emu/GuestThunks"
    shutil.copytree(source / "lib/fex-emu/HostThunks", host_thunks)
    host_thunks32 = host_thunks.with_name("HostThunks_32")
    shutil.copytree(source / "lib/fex-emu/HostThunks_32", host_thunks32)
    shutil.copytree(source / "share/fex-emu/GuestThunks", guest_thunks)
    shutil.copytree(source / "share/fex-emu/GuestThunks_32", guest_thunks.with_name("GuestThunks_32"))
    # The Nix guest toolchains use -nodefaultlibs. Their C++ thunks otherwise
    # have undefined standard-library/unwind symbols and no DT_NEEDED entries
    # (nixpkgs#513303), which fails for C games that do not already load them.
    for directory in (guest_thunks, guest_thunks.with_name("GuestThunks_32")):
        for path in directory.glob("*.so"):
            # FEX maps this kernel-style image itself and uses its callback
            # return trampoline. It has no C++ imports or dynamic dependencies.
            if path.name == "libVDSO-guest.so":
                continue
            path.chmod(path.stat().st_mode | 0o200)
            subprocess.run([
                "patchelf", "--add-needed", "libstdc++.so.6",
                "--add-needed", "libgcc_s.so.1", str(path),
            ], check=True)
            mark_nodelete(path)
    for directory in (host_thunks, host_thunks32):
        for path in directory.rglob("*.so"):
            if elf_machine(path) == 183:
                patch(path, "$ORIGIN/../..")
    for name in ("emulator.json", "ConfigTemplate.json", "VERSIONS.txt"):
        shutil.copy2(source / name, destination / name)
    template_path = destination / "ConfigTemplate.json"
    template_path.chmod(0o644)
    template = json.loads(template_path.read_text())
    template["ThunksDB"] = {
        "Vulkan": "1", "GL": "0", "drm": "0", "asound": "0", "WaylandClient": "0",
    }
    template_path.write_text(json.dumps(template, indent=2) + "\n")
    database = json.loads((source / "share/fex-emu/ThunksDB.json").read_text())
    # Include pressure-vessel's captured-library paths and the actual Nix paths
    # behind the rootfs's symlinks. Otherwise a loader may map a guest thunk stub
    # without FEX recognising it as a thunk, leading to a NoExec fault.
    for entry in database["DB"].values():
        overlays = entry["Overlay"]
        names = {Path(value).name for value in overlays}
        for name in names:
            for libdir_name in ("lib64", "lib32"):
                path = rootfs / "usr" / libdir_name / name
                if path.exists():
                    for alias in library_aliases(rootfs, path):
                        overlays.append("/" + str(alias.relative_to(rootfs)))
                        overlays.append(str(alias))
        for name in {Path(value).name for value in overlays}:
            for arch in ("x86_64-linux-gnu", "i386-linux-gnu"):
                for prefix in ("/usr/lib/pressure-vessel/overrides/lib", "/usr/lib/pressure-vessel/overrides", "/overrides/lib"):
                    overlays.append(f"{prefix}/{arch}/{name}")
        entry["Overlay"] = sorted(set(overlays))
    (destination / "usr/share/fex-emu/ThunksDB.json").write_text(json.dumps(database, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source", "destination", "closure", "rootfs"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    install(args.source, args.destination, args.closure, args.rootfs)
