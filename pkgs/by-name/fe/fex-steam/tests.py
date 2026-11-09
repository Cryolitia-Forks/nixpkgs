import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("launcher", "launcher.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
spec = importlib.util.spec_from_file_location("installer", "install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class Executed(Exception):
    pass


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.tool = self.directory / "tool"
        self.rootfs = self.directory / "rootfs"
        self.tool.mkdir()
        (self.tool / "ConfigTemplate.json").write_text(json.dumps({
            "Config": {"Env": ["EXISTING_SETTING=preserved"]}, "ThunksDB": {"Vulkan": "1"},
        }))
        launcher.ROOTFS = str(self.rootfs)
        self.environment = {"STEAM_COMPAT_DATA_PATH": str(self.directory / "data")}
        self.calls = []

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, machine):
        path = self.directory / str(machine)
        path.write_bytes(b"\x7fELF\x02\x01" + bytes(12) + struct.pack("<H", machine))
        return str(path)

    def execute(self, arguments):
        def capture(*args):
            self.calls.append(args)
            raise Executed
        with patch.object(os, "execve", capture), patch.object(os, "execvpe", capture):
            with self.assertRaises(Executed):
                launcher.launch(arguments, self.tool, self.environment)
        return self.calls[0]

    def guest_environment(self):
        template = json.loads(Path(self.environment["FEX_STEAM_CONFIG_TEMPLATE"]).read_text(),
                              object_pairs_hook=lambda pairs: pairs)
        config = next(value for name, value in template if name == "Config")
        return dict(value.split("=", 1) for name, value in config if name == "Env")

    def host_environment(self):
        template = json.loads(Path(self.environment["FEX_STEAM_CONFIG_TEMPLATE"]).read_text(),
                              object_pairs_hook=lambda pairs: pairs)
        config = next(value for name, value in template if name == "Config")
        return [value for name, value in config if name == "HostEnv"]

    def elf_dynamic_fixture(self, bits):
        header, phsize, word = (64, 56, 8) if bits == 64 else (52, 32, 4)
        dynamic = header + phsize
        data = bytearray(dynamic + 4 * word)
        data[:7] = b"\x7fELF" + bytes((2 if bits == 64 else 1, 1, 1))
        struct.pack_into("<HHI", data, 16, 3, 62 if bits == 64 else 3, 1)
        if bits == 64:
            struct.pack_into("<Q", data, 32, header)
            struct.pack_into("<HHH", data, 52, header, phsize, 1)
            struct.pack_into("<IIQQQQQQ", data, header, 2, 6, dynamic, 0, 0, 4 * word, 4 * word, word)
            struct.pack_into("<QQ", data, dynamic, 0x6FFFFFFB, 0x101)
        else:
            struct.pack_into("<I", data, 28, header)
            struct.pack_into("<HHH", data, 40, header, phsize, 1)
            struct.pack_into("<IIIIIIII", data, header, 2, dynamic, 0, 0, 4 * word, 4 * word, 6, word)
            struct.pack_into("<II", data, dynamic, 0x6FFFFFFB, 0x101)
        return data, header, dynamic, word

    def test_nodelete_only_updates_its_flag_for_both_elf_classes(self):
        for bits in (32, 64):
            with self.subTest(bits=bits):
                data, _, dynamic, word = self.elf_dynamic_fixture(bits)
                expected = bytearray(data)
                struct.pack_into("<Q" if bits == 64 else "<I", expected, dynamic + word, 0x109)
                path = self.directory / "guest.so"
                path.write_bytes(data)
                installer.mark_nodelete(path)
                self.assertEqual(path.read_bytes(), expected)

    def test_malformed_elf_bounds_are_rejected_without_writing(self):
        for bits in (32, 64):
            data, header, _, _ = self.elf_dynamic_fixture(bits)
            malformed = {"short-ident": data[:4], "short-header": data[:header - 1]}
            for case in ("phsize", "phoff", "dynamic-size", "dynamic-overrun", "big-endian"):
                image = bytearray(data)
                if case == "phsize":
                    struct.pack_into("<H", image, 54 if bits == 64 else 42, 1)
                elif case == "phoff":
                    struct.pack_into("<Q" if bits == 64 else "<I", image, 32 if bits == 64 else 28, len(image))
                elif case in ("dynamic-size", "dynamic-overrun"):
                    struct.pack_into("<Q" if bits == 64 else "<I", image,
                                     header + (32 if bits == 64 else 16),
                                     1 if case == "dynamic-size" else len(image))
                else:
                    image[5] = 2
                malformed[case] = image
            for case, image in malformed.items():
                with self.subTest(bits=bits, case=case):
                    path = self.directory / "malformed.so"
                    path.write_bytes(image)
                    with self.assertRaises(ValueError):
                        installer.mark_nodelete(path)
                    self.assertEqual(path.read_bytes(), image)

    def test_x86_game_uses_fex_without_steam_verb(self):
        game = self.executable(62)
        executable, arguments, environment = self.execute(["waitforexitandrun", "--", game, "a b"])
        self.assertEqual(executable, str(self.tool / "FEXCompatTool"))
        self.assertEqual(arguments[1:], [game, "a b"])
        self.assertEqual(environment["STEAM_COMPAT_EMULATOR"], str(self.tool / "emulator.json"))
        self.assertEqual(environment["STEAM_COMPAT_GRAPHICS_PROVIDER"], str(self.rootfs / "graphics-provider.json"))
        self.assertEqual(environment["STEAM_COMPAT_MACHINE_ARCHITECTURE"], "aarch64-linux-gnu")

    def test_i386_game_uses_same_tool(self):
        game = self.executable(3)
        self.assertEqual(self.execute(["run", "--", game])[1][1], game)
        self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
        self.assertEqual(self.environment[launcher.AUTO_ZINK], "1")

    def test_64_bit_vulkan_guests_enable_runtime_defaults_without_changing_host(self):
        self.environment.update(GALLIUM_DRIVER="native-host-driver", LIBGL_KOPPER_DISABLE="1")
        self.execute([self.executable(62)])
        guest = self.guest_environment()
        self.assertNotIn("GALLIUM_DRIVER", guest)
        self.assertNotIn("MESA_LOADER_DRIVER_OVERRIDE", guest)
        self.assertNotIn("LIBGL_KOPPER_DISABLE", guest)
        self.assertEqual(self.environment[launcher.AUTO_ZINK], "1")
        self.assertEqual(self.environment[launcher.AUTO_ZINK + "_ROOTFS"], str(self.rootfs))
        self.assertEqual(self.environment[launcher.AUTO_ZINK + "_APP_CONFIG"],
                         str(self.directory / "data/fex-emu/app_config.json"))
        self.assertIn("GALLIUM_DRIVER=native-host-driver", self.host_environment())
        self.assertIn("LIBGL_KOPPER_DISABLE=1", self.host_environment())
        self.assertEqual(self.environment["GALLIUM_DRIVER"], "native-host-driver")
        self.assertEqual(self.environment["LIBGL_KOPPER_DISABLE"], "1")

    def test_explicit_vulkan_disabled_does_not_force_zink(self):
        for options in ("ThunksDB_Vulkan:0", "ThunksDB_GL:1,ThunksDB_Vulkan:0"):
            with self.subTest(options=options):
                self.environment["STEAM_COMPAT_FEX_CONFIG"] = options
                self.execute([self.executable(62)])
                self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
                self.assertNotIn(launcher.AUTO_ZINK, self.environment)

    def test_steam_empty_or_unrelated_flags_keep_nix_vulkan_default(self):
        for options in ("", "TSOEnabled:0,Multiblock:0", "ThunksDB_GL:1"):
            with self.subTest(options=options):
                self.environment.pop("FEX_STEAM_CONFIG_TEMPLATE", None)
                self.environment["STEAM_COMPAT_FEX_CONFIG"] = options
                self.execute([self.executable(62)])
                expected = options + ("," if options else "") + "ThunksDB_Vulkan:1"
                self.assertEqual(self.environment["STEAM_COMPAT_FEX_CONFIG"], expected)
                self.assertEqual(self.environment[launcher.AUTO_ZINK], "1")
                self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())

    def test_unknown_script_defers_architecture_to_fex(self):
        self.execute(["/some/game/launch.sh"])
        self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
        self.assertEqual(self.environment[launcher.AUTO_ZINK], "1")
        self.assertIn("GALLIUM_DRIVER", self.host_environment())

    def test_expert_app_configuration_does_not_force_zink(self):
        for configuration in ("/custom/app.json", ""):
            with self.subTest(configuration=configuration):
                self.environment["FEX_APP_CONFIG"] = configuration
                self.environment["STEAM_COMPAT_FEX_CONFIG"] = ""
                self.execute([self.executable(62)])
                self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
                self.assertEqual(self.environment["STEAM_COMPAT_FEX_CONFIG"], "")
                self.assertNotIn(launcher.AUTO_ZINK, self.environment)

    def test_explicit_guest_driver_environment_does_not_force_zink(self):
        self.environment["FEX_ENV"] = "MESA_LOADER_DRIVER_OVERRIDE=llvmpipe"
        self.execute([self.executable(62)])
        self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
        self.assertNotIn(launcher.AUTO_ZINK, self.environment)

    def test_turnip_coherent_memory_default_is_scoped_to_fex(self):
        self.execute(["/some/game/launch.sh"])
        self.assertEqual(self.environment["tu_override_uncached_as_cache_coherent"], "true")

    def test_explicit_turnip_memory_setting_is_preserved(self):
        for value in ("false", ""):
            with self.subTest(value=value):
                self.environment["tu_override_uncached_as_cache_coherent"] = value
                self.execute([self.executable(62)])
                self.assertEqual(self.environment["tu_override_uncached_as_cache_coherent"], value)

    def test_dotnet_default_is_inherited_by_emulated_programs_and_scripts(self):
        for command in (self.executable(62), self.executable(3), "/game/launch.sh"):
            with self.subTest(command=command):
                self.environment = {"STEAM_COMPAT_DATA_PATH": str(self.directory / "data")}
                self.calls.clear()
                executable, arguments, environment = self.execute(["run", "--", command, "kept argument"])
                self.assertEqual(executable, str(self.tool / "FEXCompatTool"))
                self.assertEqual(arguments[1:], [command, "kept argument"])
                self.assertEqual(environment["DOTNET_EnableWriteXorExecute"], "0")

    def test_explicit_dotnet_default_is_preserved(self):
        for value in ("", "0", "1"):
            with self.subTest(value=value):
                self.environment = {
                    "STEAM_COMPAT_DATA_PATH": str(self.directory / "data"),
                    "DOTNET_EnableWriteXorExecute": value,
                }
                self.calls.clear()
                _, _, environment = self.execute(["/game/launch.sh"])
                self.assertEqual(environment["DOTNET_EnableWriteXorExecute"], value)

    def test_legacy_complus_setting_is_not_shadowed_by_dotnet_default(self):
        for value in ("", "0", "1"):
            with self.subTest(value=value):
                self.environment = {
                    "STEAM_COMPAT_DATA_PATH": str(self.directory / "data"),
                    "COMPlus_EnableWriteXorExecute": value,
                }
                self.calls.clear()
                _, _, environment = self.execute(["/game/launch.sh"])
                self.assertEqual(environment["COMPlus_EnableWriteXorExecute"], value)
                self.assertNotIn("DOTNET_EnableWriteXorExecute", environment)

    def test_dotnet_default_defers_to_fex_guest_environment(self):
        for name in ("DOTNET_EnableWriteXorExecute", "COMPlus_EnableWriteXorExecute"):
            for value in ("", "0", "1"):
                with self.subTest(name=name, value=value):
                    setting = name + "=" + value
                    self.environment = {
                        "STEAM_COMPAT_DATA_PATH": str(self.directory / "data"), "FEX_ENV": setting,
                    }
                    self.calls.clear()
                    _, _, environment = self.execute(["/game/launch.sh"])
                    self.assertEqual(environment["FEX_ENV"], setting)
                    self.assertNotIn("DOTNET_EnableWriteXorExecute", environment)

    def test_dotnet_default_defers_to_expert_fex_configuration(self):
        for name in ("FEX_APP_CONFIG", "FEX_STEAM_CONFIG_TEMPLATE"):
            for value in ("", "/expert/config.json"):
                with self.subTest(name=name, value=value):
                    self.environment = {
                        "STEAM_COMPAT_DATA_PATH": str(self.directory / "data"), name: value,
                    }
                    self.calls.clear()
                    _, _, environment = self.execute(["/game/launch.sh"])
                    if name == "FEX_APP_CONFIG" or value:
                        self.assertEqual(environment[name], value)
                    self.assertNotIn("DOTNET_EnableWriteXorExecute", environment)

    def test_nested_launch_rechecks_automatic_graphics_policy(self):
        cases = (
            {"STEAM_COMPAT_FEX_CONFIG": "ThunksDB_Vulkan:0"},
            {"FEX_APP_CONFIG": "/expert/app.json"},
            {"FEX_STEAM_CONFIG_TEMPLATE": "/expert/template.json"},
            {"FEX_ROOTFS": "/expert/rootfs"},
            {"FEX_ROOTFS": ""},
            {"FEX_ENV": "GALLIUM_DRIVER=llvmpipe"},
        )
        for settings in cases:
            with self.subTest(settings=settings):
                environment = {
                    "STEAM_COMPAT_DATA_PATH": str(self.directory / "nested"),
                    **{name: "inherited" for name in launcher.AUTO_ZINK_MARKERS},
                    **settings,
                }
                with patch.object(os, "execve", side_effect=Executed):
                    with self.assertRaises(Executed):
                        launcher.launch([self.executable(62)], self.tool, environment)
                self.assertTrue(all(name not in environment for name in launcher.AUTO_ZINK_MARKERS))

    def test_container_entry_drops_inherited_automatic_graphics_policy(self):
        self.environment.update({name: "inherited" for name in launcher.AUTO_ZINK_MARKERS})
        self.execute(["/runtime/_v2-entry-point", "--", "/game"])
        self.assertTrue(all(name not in self.environment for name in launcher.AUTO_ZINK_MARKERS))

    def test_native_arm_game_bypasses_emulator(self):
        game = self.executable(183)
        self.environment.update(STEAM_COMPAT_EMULATOR="old", STEAM_COMPAT_GRAPHICS_PROVIDER="old")
        executable, _, environment = self.execute([game])
        self.assertEqual(executable, game)
        self.assertNotIn("STEAM_COMPAT_EMULATOR", environment)
        self.assertNotIn("STEAM_COMPAT_GRAPHICS_PROVIDER", environment)
        self.assertNotIn("tu_override_uncached_as_cache_coherent", environment)
        self.assertNotIn("DOTNET_EnableWriteXorExecute", environment)

    def test_container_setup_is_not_wrapped_as_x86(self):
        command = "/some/SteamLinuxRuntime_sniper/_v2-entry-point"
        executable, _, environment = self.execute(["waitforexitandrun", "--", command, "--", "/game"])
        self.assertEqual(executable, command)
        self.assertIn("STEAM_COMPAT_EMULATOR", environment)

    def test_empty_container_rootfs_is_preserved(self):
        self.environment["FEX_ROOTFS"] = ""
        self.execute([self.executable(62)])
        self.assertEqual(self.environment["FEX_ROOTFS"], "")
        self.assertNotIn("FEX_STEAM_CONFIG_TEMPLATE", self.environment)

    def test_direct_guest_graphics_paths_do_not_change_native_thunk_environment(self):
        self.environment.update(
            LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri",
            __EGL_VENDOR_LIBRARY_FILENAMES="/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json",
            VK_DRIVER_FILES="/run/opengl-driver/share/vulkan/icd.d/freedreno_icd.aarch64.json",
        )
        for directory in ("glvnd/egl_vendor.d", "vulkan/icd.d"):
            path = self.rootfs / "usr/share" / directory
            path.mkdir(parents=True)
            (path / "64-mesa.json").write_text("{}")
            (path / "32-mesa.json").write_text("{}")
        self.execute([self.executable(62)])
        template = json.loads(Path(self.environment["FEX_STEAM_CONFIG_TEMPLATE"]).read_text(),
                              object_pairs_hook=lambda pairs: pairs)
        config = next(value for name, value in template if name == "Config")
        entries = [value for name, value in config if name == "Env"]
        self.assertGreater(len(entries), 5)
        self.assertTrue(all(isinstance(value, str) for value in entries))
        guest = dict(value.split("=", 1) for value in entries)
        self.assertEqual(guest["LIBGL_DRIVERS_PATH"], "/usr/lib64/dri:/usr/lib32/dri")
        self.assertEqual(guest["EXISTING_SETTING"], "preserved")
        self.assertEqual(guest["VK_DRIVER_FILES"],
                         "/usr/share/vulkan/icd.d/32-mesa.json:/usr/share/vulkan/icd.d/64-mesa.json")
        self.assertEqual(self.environment["LIBGL_DRIVERS_PATH"], "/run/opengl-driver/lib/dri")
        self.assertTrue(self.environment["VK_DRIVER_FILES"].startswith("/run/opengl-driver/"))

    def test_host_graphics_survive_guest_shell_exec(self):
        self.environment.update(
            LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri",
            __EGL_VENDOR_LIBRARY_FILENAMES="/native/egl.json",
            VK_DRIVER_FILES="/native/aarch64.json",
            VK_ICD_FILENAMES="",
        )
        for directory in ("glvnd/egl_vendor.d", "vulkan/icd.d"):
            path = self.rootfs / "usr/share" / directory
            path.mkdir(parents=True)
            (path / "64-mesa.json").write_text("{}")
        self.execute([self.executable(62)])
        host_entries = self.host_environment()
        self.assertTrue(all(isinstance(value, str) for value in host_entries))
        host = dict((value.split("=", 1) if "=" in value else (value, None))
                    for value in host_entries)
        self.assertEqual(host["LIBGL_DRIVERS_PATH"], "/run/opengl-driver/lib/dri")
        self.assertEqual(host["__EGL_VENDOR_LIBRARY_FILENAMES"], "/native/egl.json")
        self.assertEqual(host["VK_DRIVER_FILES"], "/native/aarch64.json")
        self.assertEqual(host["VK_ICD_FILENAMES"], "")
        for name in ("VK_ADD_DRIVER_FILES", "__EGL_VENDOR_LIBRARY_DIRS", "LIBVA_DRIVERS_PATH",
                     "GBM_BACKENDS_PATH", "__GLX_VENDOR_LIBRARY_NAME",
                     "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "LIBGL_KOPPER_DISABLE"):
            self.assertIsNone(host[name], name)
        # Simulate guest exec reusing the guest environment, then FEX restoring
        # HostEnv. None means putenv(NAME), which removes the guest setting.
        next_host = {**self.environment, **self.guest_environment()}
        for name, value in host.items():
            if value is None:
                next_host.pop(name, None)
            else:
                next_host[name] = value
        self.assertEqual(next_host["VK_DRIVER_FILES"], "/native/aarch64.json")
        self.assertEqual(next_host["VK_ICD_FILENAMES"], "")
        self.assertNotIn("VK_ADD_DRIVER_FILES", next_host)
        self.assertNotIn("GALLIUM_DRIVER", next_host)

    def test_existing_host_environment_is_retained_before_graphics_restoration(self):
        (self.tool / "ConfigTemplate.json").write_text(json.dumps({
            "Config": {"HostEnv": ["UNRELATED_SETTING=preserved", "LIBGL_DRIVERS_PATH=/stale"]},
            "ThunksDB": {"Vulkan": "1"},
        }))
        self.environment["LIBGL_DRIVERS_PATH"] = "/native/drivers"
        self.execute([self.executable(62)])
        host = self.host_environment()
        self.assertEqual(host[:2], ["UNRELATED_SETTING=preserved", "LIBGL_DRIVERS_PATH=/stale"])
        self.assertGreater(host.index("LIBGL_DRIVERS_PATH=/native/drivers"), 1)

    def test_script_protects_native_driver_settings_before_runtime_selection(self):
        self.execute(["/some/game/launch.sh"])
        host = self.host_environment()
        self.assertIn("LIBGL_DRIVERS_PATH", host)
        self.assertIn("GALLIUM_DRIVER", host)
        self.assertNotIn("GALLIUM_DRIVER", self.guest_environment())
        self.assertEqual(self.environment[launcher.AUTO_ZINK], "1")

    def test_user_template_override_is_preserved(self):
        self.environment["FEX_STEAM_CONFIG_TEMPLATE"] = "/custom/template.json"
        self.execute([self.executable(62)])
        self.assertEqual(self.environment["FEX_STEAM_CONFIG_TEMPLATE"], "/custom/template.json")

    def test_vulkan_thunks_default_can_be_overridden(self):
        self.execute([self.executable(62)])
        self.assertEqual(self.environment["STEAM_COMPAT_FEX_CONFIG"], "ThunksDB_Vulkan:1")
        self.environment["STEAM_COMPAT_FEX_CONFIG"] = "ThunksDB_Vulkan:0"
        self.execute([self.executable(62)])
        self.assertEqual(self.environment["STEAM_COMPAT_FEX_CONFIG"], "ThunksDB_Vulkan:0")

    def test_nix_soname_alias_is_registered_as_well_as_real_file(self):
        library = self.rootfs / "nix/store/vulkan-loader/lib/libvulkan.so.1.4"
        library.parent.mkdir(parents=True)
        library.touch()
        soname = library.with_name("libvulkan.so.1")
        soname.symlink_to(library.name)
        public = self.rootfs / "usr/lib64/libvulkan.so.1"
        public.parent.mkdir(parents=True)
        public.symlink_to("../../nix/store/vulkan-loader/lib/libvulkan.so.1")
        self.assertEqual(set(installer.library_aliases(self.rootfs, public)), {public, soname, library})

    def test_native_container_helper_retains_emulation(self):
        helper = self.directory / "pressure-vessel-wrap"
        helper.write_bytes(Path(self.executable(183)).read_bytes())
        executable, _, environment = self.execute([str(helper), "--", "/game"])
        self.assertEqual(executable, str(helper))
        self.assertIn("STEAM_COMPAT_EMULATOR", environment)
        self.assertIn("STEAM_COMPAT_GRAPHICS_PROVIDER", environment)

    def test_explicit_provider_is_preserved(self):
        self.environment["STEAM_COMPAT_GRAPHICS_PROVIDER"] = "/custom/provider.json"
        self.execute([self.executable(62)])
        self.assertEqual(self.environment["STEAM_COMPAT_GRAPHICS_PROVIDER"], "/custom/provider.json")

    def test_empty_data_path_uses_writable_per_game_cache(self):
        self.environment.update(
            STEAM_COMPAT_DATA_PATH="", XDG_CACHE_HOME=str(self.directory / "cache"),
            STEAM_COMPAT_APP_ID="12345",
        )
        self.execute([self.executable(62)])
        expected = self.directory / "cache/fex-steam/12345"
        self.assertEqual(self.environment["STEAM_COMPAT_DATA_PATH"], str(expected))
        self.assertTrue(expected.is_dir())

    def test_empty_cache_home_does_not_use_working_directory(self):
        self.environment.update(STEAM_COMPAT_DATA_PATH="", XDG_CACHE_HOME="", SteamAppId="67890")
        with patch.object(Path, "home", return_value=self.directory):
            self.execute([self.executable(62)])
        self.assertEqual(
            self.environment["STEAM_COMPAT_DATA_PATH"], str(self.directory / ".cache/fex-steam/67890")
        )


unittest.main()
