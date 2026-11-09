#!@bash@/bin/bash

# Valve's installed ARM64 client is mutable, just like the x86 client.
# Keep the bootstrap immutable in the store and run a per-user copy in the
# native FHS environment provided by pkgs.steam.
set -euo pipefail

export PATH="@coreutils@/bin:@gnugrep@/bin:@gnused@/bin:@utilLinux@/bin:$PATH"

steam_config="${HOME%/}/.steam"
steam_root="${XDG_DATA_HOME:-$HOME/.local/share}/Steam"

# Reuse the current installation, including installations on another disk.
# Do not redirect an existing game library to a fresh default directory.
for existing in "$steam_config/steam" "$steam_config/root"; do
    if [ -d "$existing" ]; then
        steam_root="$(readlink -f -- "$existing")"
        break
    fi
done

mkdir -p -- "$steam_config" "$steam_root"
steam_root="$(readlink -f -- "$steam_root")"
steam_runtime="$steam_root/steamrtarm64"
client_ready="$steam_root/.nixpkgs-steam-arm64-ready"

bootstrap_usable() {
    [ -f "$steam_runtime/steam" ] \
        && [ -e "$steam_runtime/libSDL3.so.0" ] \
        && compgen -G "$steam_runtime/libavcodec.so.*" > /dev/null
}

elf_matches() {
    local library="$1" expected_class="$2" expected_machine="$3"
    local -a header=()
    [ -f "$library" ] || return 1
    read -r -a header < <(od -An -v -tu1 -w20 -N20 -- "$library")
    [ "${#header[@]}" -eq 20 ] \
        && [ "${header[*]:0:4}" = '127 69 76 70' ] \
        && [ "${header[4]}" -eq "$expected_class" ] \
        && [ "${header[5]}" -eq 1 ] \
        && [ "${header[18]}" -eq "$expected_machine" ] \
        && [ "${header[19]}" -eq 0 ]
}

client_complete() {
    bootstrap_usable \
        && [ -f "$steam_root/steam.sh" ] \
        && [ -f "$steam_root/public/steambootstrapper_english.txt" ] \
        && [ -f "$steam_runtime/steamclient.so" ] \
        && [ -f "$steam_runtime/steamwebhelper" ] \
        && [ -f "$steam_runtime/libcef.so" ] \
        && elf_matches "$steam_root/linux32/steamclient.so" 1 3 \
        && elf_matches "$steam_root/linux64/steamclient.so" 2 62 \
        && elf_matches "$steam_root/linuxarm64/steamclient.so" 2 183
}

restore_sdk() {
    local arch="$1" expected_class="$2" expected_machine="$3" temporary
    local library="$steam_root/$arch/steamclient.so"
    if elf_matches "$library" "$expected_class" "$expected_machine"; then
        return
    fi
    # A valid newer SDK belongs to Steam's updater. Only bootstrap an absent
    # or wrong-architecture SDK, and preserve existing supporting SDK files.
    rm -f -- "$client_ready"
    mkdir -p -- "$steam_root/$arch"
    cp -R --no-preserve=mode --update=none -- @bootstrap@/"$arch"/. "$steam_root/$arch/"
    if ! elf_matches "$library" "$expected_class" "$expected_machine"; then
        temporary="$(mktemp "$steam_root/$arch/.steamclient.XXXXXX")"
        cp --reflink=auto --no-preserve=mode -- @bootstrap@/"$arch"/steamclient.so "$temporary"
        mv -fT -- "$temporary" "$library"
    fi
}

repair=false
if [ "${1-}" = --reset ]; then
    # Restore bootstrap files while leaving steamapps, userdata and settings
    # alone. Steam downloads the remaining client files again below.
    repair=true
    shift
fi

link_directory() {
    local target="$1" link="$2"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        if [ -d "$link" ] && [ "$(readlink -f -- "$link")" = "$target" ]; then
            return
        fi
        printf 'Steam: refusing to replace non-symlink path: %s\n' "$link" >&2
        exit 1
    fi
    ln -sfnT -- "$target" "$link"
}

link_directory "$steam_root" "$steam_config/steam"
link_directory "$steam_root" "$steam_config/root"
link_directory "$steam_root/linux32" "$steam_config/sdk32"
link_directory "$steam_root/linux64" "$steam_config/sdk64"
link_directory "$steam_root/linuxarm64" "$steam_config/sdkarm64"

export STEAMSCRIPT="$0"
export SYSTEM_PATH="$PATH"
export SYSTEM_LD_LIBRARY_PATH="${LD_LIBRARY_PATH-}"
export LD_LIBRARY_PATH="$steam_runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# A host setting of STEAM_RUNTIME prevents pressure-vessel from starting.
# This also applies to the first native bootstrap update, before steam.sh.
unset STEAM_RUNTIME STEAM_RUNTIME_LIBRARY_PATH

cd -- "$steam_root"

# Serialize extraction and the initial update, rechecking completeness only
# after taking the lock. Release it before launching the long-running client
# so a second steam:// invocation can immediately contact that client.
(
    flock 9
    if "$repair" || ! bootstrap_usable; then
        # Replacing this small set of client files also repairs an interrupted
        # copy which left a truncated but existing executable or library.
        if "$repair"; then
            cp -R --no-preserve=mode -- @bootstrap@/. "$steam_root/"
        else
            # A bootstrap repair must not downgrade SDKs already updated by
            # Steam. They are checked and repaired separately below.
            for component in @bootstrap@/*; do
                case "${component##*/}" in
                    linux32|linux64|linuxarm64) continue ;;
                esac
                cp -R --no-preserve=mode -- "$component" "$steam_root/"
            done
        fi
        chmod -R u+rwX -- "$steam_runtime"
        chmod u+x -- "$steam_runtime/steam"
        rm -f -- "$client_ready"
    fi

    # The native manifest supplies three Steamworks SDKs. ARM64 cannot replace
    # the x86 SDK needed by libsteam_api.so running under FEX. Seed them before
    # the update so SDK downloads delayed until login cannot prevent bootstrap.
    restore_sdk linux32 1 3
    restore_sdk linux64 2 62
    restore_sdk linuxarm64 2 183

    if [ ! -f "$client_ready" ] || ! client_complete; then
        # The native bootstrap fills in Steam Runtime, the browser, SDKs and
        # shared resources. No account sign-in is required for this update.
        rm -f -- "$client_ready"
        for attempt in 1 2 3; do
            # Do not let an updater subprocess inherit our initialization lock.
            if "$steam_runtime/steam" -forcesteamupdate -forcepackagedownload -exitsteam 9>&-; then
                status=0
            else
                status=$?
            fi
            case "$status" in
                0|42|254) ;;
                *) exit "$status" ;;
            esac
            if client_complete; then
                touch -- "$client_ready"
                break
            fi
            printf 'Steam: client update %s left an incomplete installation; retrying.\n' "$attempt" >&2
        done
        if ! client_complete; then
            printf '%s\n' 'Steam: native client installation is incomplete after three update attempts.' >&2
            exit 1
        fi
    fi
) 9> "$steam_root/.nixpkgs-steam-arm64-bootstrap.lock"

restarts=0
while true; do
    # Adapt a private copy of Valve's shared launcher instead of replacing an
    # existing steamrt64 directory or modifying the self-updated steam.sh.
    # This changes the client entry point, not the runtime ABI of its games.
    # Match a literal expression in Valve's script, not our environment.
    # shellcheck disable=SC2016
    if ! grep -Fq '"$STEAMROOT/steamrt64/steam"' "$steam_root/steam.sh"; then
        printf '%s\n' 'Steam: the updated steam.sh has an unsupported native-client entry point.' >&2
        exit 1
    fi
    launcher="$(mktemp "$steam_root/.nixpkgs-steam-arm64.XXXXXX")"
    # SteamRT3c's create_legacy_entry_points replaces the real x86 scout
    # runtime with shims to its x86 SteamRT3c tools. The native client has no
    # equivalent client runtime: our native FHS supplies ARM64 host dependencies.
    # Preserve any existing x86 scout directory instead of replacing it with
    # those shims. This does not unpack or activate scout for a fresh install.
    # Each game's compatibility tool supplies its runtime independently: ARM64
    # Proton requires Runtime 4, while games needing the scout ABI need a
    # separate scout-compatible runtime rather than the direct FEX RootFS.
    # Only the two executable paths need to change; other steamrt64 paths
    # belong to the separate x86 runtime and must not be rewritten.
    # The replacements operate on the upstream script's shell variables.
    # shellcheck disable=SC2016
    sed \
        -e 's#"\$STEAMROOT/steamrt64/steam"#"$STEAMROOT/steamrtarm64/steam"#g' \
        -e 's/^[[:space:]]*create_legacy_entry_points[[:space:]]*$/        : # Keep the x86 scout runtime./' \
        -e 's/^\([[:space:]]*\)exec "\$0" "\$@"[[:space:]]*$/\1exit "$STATUS"/' \
        "$steam_root/steam.sh" > "$launcher"
    chmod u+x -- "$launcher"
    mv -fT -- "$launcher" "$steam_root/.nixpkgs-steam-arm64.sh"

    # Take the shared launcher's SteamRT path (runtime environment cleanup and
    # restart handling), executing the ARM64 binary instead of its x86 peer.
    export STEAM_FORCE_CLIENT=steamrt64
    export STEAMEXE=steam
    if @bash@/bin/bash "$steam_root/.nixpkgs-steam-arm64.sh" "$@"; then
        exit 0
    else
        status=$?
    fi
    if [ "$status" -ne 42 ]; then
        exit "$status"
    fi
    restarts=$((restarts + 1))
    if [ "$restarts" -ge 5 ]; then
        printf '%s\n' 'Steam: stopping after five consecutive client restart requests.' >&2
        exit 42
    fi
done
