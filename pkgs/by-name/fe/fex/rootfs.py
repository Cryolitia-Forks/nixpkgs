"""Assemble FEX's foreign-architecture sysroot without executing guest code."""

import argparse
import json
import os
from pathlib import Path
import stat
import struct
import subprocess


def elf_machine(path):
    try:
        with path.open("rb") as stream:
            header = stream.read(20)
    except (OSError, ValueError):
        return None
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[5] != 1:
        return None
    return struct.unpack_from("<H", header, 18)[0]


def link(output, target, source):
    """Link to the copy in our own store tree, never to the builder's root."""
    if target.exists() or target.is_symlink():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    inside = output / str(source).lstrip("/")
    target.symlink_to(os.path.relpath(inside, target.parent))


def merge_libraries(output, paths, machine, libdir):
    for source in paths:
        for prefix in ("lib", "lib64"):
            directory = source / prefix
            if not directory.is_dir():
                continue
            for parent, _, filenames in os.walk(directory, followlinks=True):
                for name in filenames:
                    path = Path(parent) / name
                    if ".so" not in name or elf_machine(path) != machine:
                        continue
                    relative = path.relative_to(directory)
                    link(output, output / "usr" / libdir / relative, path)


def merge_data(output, packages, bits):
    # These are discovered by graphics loaders and pressure-vessel rather than
    # through ld.so. Other application data remains in the copied Nix closure.
    for package in packages:
        for prefix in (
            "share/vulkan", "share/glvnd", "share/drirc.d", "share/X11",
            "share/fonts", "share/i18n", "lib/locale",
        ):
            source = package / prefix
            if not source.is_dir():
                continue
            destination = output / "usr" / ("lib64/locale" if prefix == "lib/locale" else prefix)
            for parent, _, filenames in os.walk(source, followlinks=True):
                for name in filenames:
                    path = Path(parent) / name
                    relative = path.relative_to(source)
                    if prefix in ("share/vulkan", "share/glvnd") and path.suffix == ".json":
                        # Mesa's EGL vendor manifest has the same name for both
                        # ABIs, but embeds different absolute Nix store paths.
                        # Keep both: each loader rejects the other ELF class.
                        relative = relative.with_name(f"{bits}-{relative.name}")
                    link(output, destination / relative, path)


def normalize_symlinks(output):
    for parent, directories, filenames in os.walk(output, followlinks=False):
        os.chmod(parent, os.stat(parent).st_mode | stat.S_IWUSR)
        for name in directories + filenames:
            path = Path(parent) / name
            if path.is_symlink():
                target = os.readlink(path)
                if target.startswith("/"):
                    # A graphics-provider sysroot is resolved as if chrooted.
                    # Absolute Nix store links would otherwise escape its view.
                    path.unlink()
                    path.symlink_to(os.path.relpath(output / target.lstrip("/"), path.parent))


def check(output):
    manifest = json.loads((output / "graphics-provider.json").read_text())
    architectures = manifest["graphics_provider_v0"]["architectures"]
    assert set(architectures) == {"x86_64-linux-gnu", "i386-linux-gnu"}
    assert elf_machine(output / "lib64/ld-linux-x86-64.so.2") == 62
    assert elf_machine(output / "lib/ld-linux.so.2") == 3
    assert elf_machine(output / "usr/lib64/libc.so.6") == 62
    assert elf_machine(output / "usr/lib32/libc.so.6") == 3
    assert elf_machine(output / "sbin/ldconfig") == 3
    cache = (output / "etc/ld.so.cache").read_bytes()
    assert cache.startswith(b"glibc-ld.so.cache1.1")
    count = struct.unpack_from("<I", cache, 20)[0]
    machines = set()
    for index in range(count):
        flags, key, value, _, _ = struct.unpack_from("<iIIIQ", cache, 48 + 24 * index)
        assert 0 <= key < len(cache) and 0 <= value < len(cache)
        library = cache[value:cache.index(b"\0", value)].decode()
        # Resolve like a sysroot consumer, without falling back to the builder's
        # /nix/store. The self-alias makes paths containing our output work too.
        path = (output / library.lstrip("/")).resolve(strict=True)
        assert path.is_relative_to(output), (library, path)
        machine = elf_machine(path)
        expected_machine = 62 if flags & 0xFF00 == 0x0300 else 3
        assert machine == expected_machine, (library, flags, machine)
        machines.add(machine)
    assert machines == {3, 62}, machines
    for parent, directories, filenames in os.walk(output, followlinks=False):
        for name in directories + filenames:
            path = Path(parent) / name
            if path.is_symlink():
                assert not os.readlink(path).startswith("/"), path
    for arch, machine in (("lib64", 62), ("lib32", 3)):
        # Nix glibc was configured with a store-prefixed sysconfdir. Ordinary
        # non-Nix games have no RUNPATH and need this default cache as well.
        libc = (output / "usr" / arch / "libc.so.6").resolve(strict=True)
        assert (libc.parent.parent / "etc/ld.so.cache").resolve(strict=True) == output / "etc/ld.so.cache"
        for library in ("libGL.so.1", "libEGL.so.1", "libvulkan.so.1", "libdrm.so.2"):
            assert elf_machine(output / "usr" / arch / library) == machine, library
    for bits, machine in ((64, 62), (32, 3)):
        vendors = list((output / "usr/share/glvnd/egl_vendor.d").glob(f"{bits}-*.json"))
        assert vendors, f"Missing {bits}-bit EGL vendor manifests"
        for vendor in vendors:
            library = json.loads(vendor.read_text())["ICD"]["library_path"]
            if library.startswith("/"):
                path = (output / library.lstrip("/")).resolve(strict=True)
                assert path.is_relative_to(output), path
                assert elf_machine(path) == machine, (vendor, library)


def build(args):
    output = Path(args.output)
    output.mkdir(parents=True)
    packages64 = [Path(path) for path in json.loads(args.packages64)]
    packages32 = [Path(path) for path in json.loads(args.packages32)]
    closure64 = [Path(path) for path in Path(args.closure64).read_text().splitlines()]
    closure32 = [Path(path) for path in Path(args.closure32).read_text().splitlines()]
    store = output / "nix/store"
    store.mkdir(parents=True)
    for source in dict.fromkeys(closure64 + closure32):
        subprocess.run(
            ["cp", "-a", "--reflink=auto", "--no-preserve=ownership", str(source), str(store)],
            check=True,
        )

    # ldconfig runs without a chroot, so the cache contains absolute Nix paths.
    # Resolve the rootfs's own path to itself when used as a sysroot or by FEX.
    (store / output.name).symlink_to("../..")
    merge_libraries(output, list(dict.fromkeys(packages64 + closure64)), 62, "lib64")
    merge_libraries(output, list(dict.fromkeys(packages32 + closure32)), 3, "lib32")
    merge_data(output, packages64, 64)
    merge_data(output, packages32, 32)
    for package in packages64:
        for prefix in ("bin", "sbin"):
            directory = package / prefix
            if directory.is_dir():
                for path in directory.iterdir():
                    link(output, output / "usr" / prefix / path.name, path)
    # i386 ldconfig correctly recognises both x86 ABIs, including patched ELFs.
    ldconfig = Path(json.loads(args.ldconfig)[-1])
    target = output / "usr/sbin/ldconfig"
    target.unlink(missing_ok=True)
    link(output, target, ldconfig)

    (output / "usr/lib").symlink_to("lib64")
    # FEX uses these directories to recognise a Debian-style multiarch rootfs
    # and pick the correct 32-bit thunk overlays as well as the 64-bit ones.
    (output / "usr/lib64/x86_64-linux-gnu").symlink_to(".")
    (output / "usr/lib64/i386-linux-gnu").symlink_to("../lib32")
    for name in ("bin", "sbin", "lib", "lib64", "lib32"):
        (output / name).symlink_to("usr/" + name)
    (output / "usr/lib64/ld-linux.so.2").symlink_to("../lib32/ld-linux.so.2")
    etc = output / "etc"
    etc.mkdir(exist_ok=True)
    (etc / "ld.so.conf").write_text(f"{output}/usr/lib64\n{output}/usr/lib32\n")
    (etc / "nsswitch.conf").write_text("hosts: files dns\npasswd: files\ngroup: files\n")
    normalize_symlinks(output)
    subprocess.run(json.loads(args.ldconfig) + [
        "-X", "--format=new", "-f", str(etc / "ld.so.conf"), "-C", str(etc / "ld.so.cache"),
    ], check=True)
    for arch in ("lib64", "lib32"):
        libc = (output / "usr" / arch / "libc.so.6").resolve(strict=True)
        libc_etc = libc.parent.parent / "etc"
        libc_etc.mkdir(exist_ok=True)
        for name in ("ld.so.cache", "ld.so.conf"):
            target = libc_etc / name
            target.unlink(missing_ok=True)
            target.symlink_to(os.path.relpath(etc / name, libc_etc))
    manifest = {"graphics_provider_v0": {
        "root": "./", "locales": False,
        "architectures": {
            "x86_64-linux-gnu": {
                "dri": "/usr/lib64/dri", "gbm": "/usr/lib64/gbm",
                "gconv": "/usr/lib64/gconv", "fallback_library_paths": ["/usr/lib64"],
            },
            "i386-linux-gnu": {
                "dri": "/usr/lib32/dri", "gbm": "/usr/lib32/gbm",
                "gconv": "/usr/lib32/gconv", "fallback_library_paths": ["/usr/lib32"],
            },
        },
    }}
    (output / "graphics-provider.json").write_text(json.dumps(manifest, indent=2) + "\n")
    check(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path)
    for name in ("output", "closure64", "closure32", "packages64", "packages32", "ldconfig"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    if args.check:
        check(args.check)
    else:
        build(args)
