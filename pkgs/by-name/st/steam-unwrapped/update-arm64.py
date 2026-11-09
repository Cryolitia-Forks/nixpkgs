#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3

"""Pin Valve's ARM64 bootstrap components, not the mutable manifest URL."""

import json
from pathlib import Path
import re
from urllib.request import urlopen


def read_vdf(text):
    tokens = iter(re.findall(r'"(?:\\.|[^"\\])*"|[{}]', text))

    def read_object(nested=False):
        result = {}
        for token in tokens:
            if token == "}":
                if not nested:
                    raise ValueError("Unexpected closing brace in manifest")
                return result
            key = json.loads(token)
            value = next(tokens)
            result[key] = read_object(True) if value == "{" else json.loads(value)
        if nested:
            raise ValueError("Unclosed object in manifest")
        return result

    return read_object()


def main():
    path = Path(__file__).with_name("arm64-sources.json")
    current = json.loads(path.read_text())
    with urlopen("https://client-update.steamstatic.com/steam_client_linuxarm64", timeout=30) as response:
        manifest = read_vdf(response.read().decode())["linuxarm64"]

    updated = {"version": manifest["version"], "components": {}}
    for name in current["components"]:
        component = manifest[name]
        filename, sha256 = component["file"], component["sha2"]
        if not re.fullmatch(r"[a-z0-9_]+\.zip\.[0-9a-f]{40}", filename):
            raise ValueError(f"Unexpected archive name: {filename}")
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ValueError(f"Invalid SHA-256 for {name}")
        updated["components"][name] = {"file": filename, "sha256": sha256}
    path.write_text(json.dumps(updated, indent=2) + "\n")


if __name__ == "__main__":
    main()
