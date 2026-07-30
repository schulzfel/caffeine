#!/bin/bash

# Shared Swift toolchain/SDK selection for build and test scripts.
# This file is sourced; it deliberately does not change shell options.

caffeine_sdk_error() {
    printf 'error: %s\n' "$*" >&2
}

caffeine_resolve_host_architecture() {
    local architecture
    architecture="$(/usr/bin/uname -m)"
    case "$architecture" in
        arm64|x86_64)
            printf '%s\n' "$architecture"
            ;;
        *)
            caffeine_sdk_error "unsupported macOS host architecture: $architecture"
            return 1
            ;;
    esac
}

caffeine_compile_host_swift_tool() {
    if [[ "$#" -ne 3 ]]; then
        caffeine_sdk_error \
            "caffeine_compile_host_swift_tool expects source, output, and cache suffix"
        return 2
    fi

    local source_file="$1"
    local output_file="$2"
    local cache_suffix="$3"
    local module_cache

    [[ -n "${CAFFEINE_HOST_TARGET:-}" ]] || {
        caffeine_sdk_error "select a Swift SDK before compiling a host tool"
        return 1
    }
    [[ -f "$source_file" ]] || {
        caffeine_sdk_error "host-tool source is missing: $source_file"
        return 1
    }
    [[ "$cache_suffix" =~ ^[A-Za-z0-9._-]+$ ]] || {
        caffeine_sdk_error "host-tool cache suffix contains invalid characters"
        return 1
    }

    module_cache="$CAFFEINE_MODULE_CACHE-host-$CAFFEINE_HOST_ARCHITECTURE-$cache_suffix"
    /bin/mkdir -p "$module_cache"
    "$CAFFEINE_SWIFTC" \
        -O \
        -target "$CAFFEINE_HOST_TARGET" \
        -sdk "$SDKROOT" \
        -module-cache-path "$module_cache" \
        "$source_file" \
        -o "$output_file"
}

caffeine_select_swift_sdk() {
    if [[ "$#" -ne 1 ]]; then
        caffeine_sdk_error "caffeine_select_swift_sdk expects the repository root"
        return 2
    fi

    local repository_root="$1"
    local swift_path
    local swiftc_path
    local host_architecture
    local explicit_sdk="${SDKROOT:-}"
    local default_sdk
    local developer_path
    local candidate
    local canonical_candidate
    local candidate_parent
    local selected_sdk=""
    local selected_key=""
    local probe_root="$repository_root/.build/sdk-probes"
    local probe_key
    local probe_directory
    local probe_log
    local seen_candidates=""
    local toolchain_fingerprint
    local candidate_fingerprint
    local probe_architecture
    local probe_succeeded
    local shared_cache_root="$repository_root/.build/swiftpm-support"
    local candidates=()
    local sdk_parents=()

    swift_path="$(/usr/bin/xcrun --find swift 2>/dev/null)" || {
        caffeine_sdk_error "Swift was not found. Install Xcode Command Line Tools."
        return 1
    }
    swiftc_path="$(/usr/bin/xcrun --find swiftc 2>/dev/null)" || {
        caffeine_sdk_error "swiftc was not found. Install Xcode Command Line Tools."
        return 1
    }
    host_architecture="$(caffeine_resolve_host_architecture)" || return 1

    /bin/mkdir -p "$probe_root"

    if [[ -n "$explicit_sdk" ]]; then
        if [[ ! -d "$explicit_sdk" ]]; then
            caffeine_sdk_error "SDKROOT does not name an SDK directory: $explicit_sdk"
            return 1
        fi
        candidates+=("$explicit_sdk")
    else
        default_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
        if [[ -n "$default_sdk" ]]; then
            candidates+=("$default_sdk")
            sdk_parents+=("$(/usr/bin/dirname "$default_sdk")")
        fi

        developer_path="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
        if [[ -n "$developer_path" ]]; then
            sdk_parents+=("$developer_path/SDKs")
            sdk_parents+=(
                "$developer_path/Platforms/MacOSX.platform/Developer/SDKs"
            )
        fi
        sdk_parents+=("/Library/Developer/CommandLineTools/SDKs")

        for candidate_parent in "${sdk_parents[@]}"; do
            [[ -d "$candidate_parent" ]] || continue
            for candidate in "$candidate_parent"/MacOSX*.sdk; do
                [[ -d "$candidate" ]] || continue
                candidates+=("$candidate")
            done
        done
    fi

    toolchain_fingerprint="$(
        "$swiftc_path" -version 2>&1 |
            /usr/bin/shasum -a 256 |
            /usr/bin/awk '{ print substr($1, 1, 12) }'
    )"

    for candidate in "${candidates[@]}"; do
        canonical_candidate="$(/bin/realpath "$candidate" 2>/dev/null || true)"
        [[ -n "$canonical_candidate" ]] || continue

        case "
$seen_candidates
" in
            *"
$canonical_candidate
"*)
                continue
                ;;
        esac
        seen_candidates="${seen_candidates}${canonical_candidate}"$'\n'

        candidate_fingerprint="$(
            printf '%s\n%s\n%s\n' \
                "$canonical_candidate" \
                "$toolchain_fingerprint" \
                "manifest-and-universal-import-probe-v4" |
                /usr/bin/shasum -a 256 |
                /usr/bin/awk '{ print substr($1, 1, 16) }'
        )"
        probe_key="$candidate_fingerprint"
        probe_directory="$probe_root/$probe_key"
        probe_log="$probe_directory/probe.log"
        /bin/mkdir -p \
            "$probe_directory/module-cache" \
            "$probe_directory/clang-module-cache" \
            "$probe_directory/scratch" \
            "$shared_cache_root/cache" \
            "$shared_cache_root/config" \
            "$shared_cache_root/security"

        if [[ -f "$probe_directory/compatible" ]]; then
            selected_sdk="$canonical_candidate"
            selected_key="$probe_key"
            break
        fi

        if SDKROOT="$canonical_candidate" \
            SWIFTPM_MODULECACHE_OVERRIDE="$probe_directory/module-cache" \
            CLANG_MODULE_CACHE_PATH="$probe_directory/clang-module-cache" \
            "$swift_path" package \
                --package-path "$repository_root" \
                --cache-path "$shared_cache_root/cache" \
                --config-path "$shared_cache_root/config" \
                --security-path "$shared_cache_root/security" \
                --scratch-path "$probe_directory/scratch" \
                --disable-sandbox \
                --manifest-cache none \
                --sdk "$canonical_candidate" \
                dump-package >"$probe_log" 2>&1; then
            probe_succeeded=1
            for probe_architecture in arm64 x86_64; do
                /bin/mkdir -p \
                    "$probe_directory/module-cache-$probe_architecture" \
                    "$probe_directory/clang-module-cache-$probe_architecture"
                if ! printf '%s\n' \
                    'import Foundation' \
                    'import AppKit' \
                    'import IOKit.pwr_mgt' \
                    'import ServiceManagement' \
                    'import OSLog' |
                    "$swiftc_path" \
                        -typecheck \
                        -target "$probe_architecture-apple-macosx14.0" \
                        -sdk "$canonical_candidate" \
                        -module-cache-path \
                        "$probe_directory/module-cache-$probe_architecture" \
                        -Xcc \
                        "-fmodules-cache-path=$probe_directory/clang-module-cache-$probe_architecture" \
                        - >>"$probe_log" 2>&1; then
                    probe_succeeded=0
                    break
                fi
            done

            if [[ "$probe_succeeded" -eq 1 ]]; then
                /usr/bin/touch "$probe_directory/compatible"
                selected_sdk="$canonical_candidate"
                selected_key="$probe_key"
                break
            fi
        fi

        if [[ -n "$explicit_sdk" ]]; then
            caffeine_sdk_error "SDKROOT is incompatible with the active Swift compiler: $canonical_candidate"
            /bin/cat "$probe_log" >&2
            return 1
        fi

        printf 'Skipping incompatible SDK: %s\n' "$canonical_candidate" >&2
    done

    if [[ -z "$selected_sdk" ]]; then
        caffeine_sdk_error "No compatible macOS SDK was found for the active Swift compiler."
        caffeine_sdk_error "Set SDKROOT to a compatible MacOSX.sdk and try again."
        return 1
    fi

    export SDKROOT="$selected_sdk"
    export CAFFEINE_SWIFT="$swift_path"
    export CAFFEINE_SWIFTC="$swiftc_path"
    export CAFFEINE_HOST_ARCHITECTURE="$host_architecture"
    export CAFFEINE_HOST_TARGET="$host_architecture-apple-macosx14.0"
    export CAFFEINE_SDK_KEY="$selected_key"
    export CAFFEINE_MODULE_CACHE="$repository_root/.build/module-cache-$selected_key"
    export CAFFEINE_CLANG_MODULE_CACHE="$repository_root/.build/clang-module-cache-$selected_key"
    export CAFFEINE_SCRATCH_PATH="$repository_root/.build/swiftpm-$selected_key"
    export CAFFEINE_SWIFTPM_CACHE="$shared_cache_root/cache"
    export CAFFEINE_SWIFTPM_CONFIG="$shared_cache_root/config"
    export CAFFEINE_SWIFTPM_SECURITY="$shared_cache_root/security"
    export SWIFTPM_MODULECACHE_OVERRIDE="$CAFFEINE_MODULE_CACHE"
    export CLANG_MODULE_CACHE_PATH="$CAFFEINE_CLANG_MODULE_CACHE"
    export CAFFEINE_DEVELOPER_FRAMEWORKS=""
    export CAFFEINE_DEVELOPER_USR_LIB=""

    developer_path="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [[ -d "$developer_path/Library/Developer/Frameworks" ]]; then
        export CAFFEINE_DEVELOPER_FRAMEWORKS="$developer_path/Library/Developer/Frameworks"
    fi
    if [[ -d "$developer_path/Library/Developer/usr/lib" ]]; then
        export CAFFEINE_DEVELOPER_USR_LIB="$developer_path/Library/Developer/usr/lib"
    fi

    /bin/mkdir -p \
        "$CAFFEINE_MODULE_CACHE" \
        "$CAFFEINE_CLANG_MODULE_CACHE" \
        "$CAFFEINE_SCRATCH_PATH" \
        "$CAFFEINE_SWIFTPM_CACHE" \
        "$CAFFEINE_SWIFTPM_CONFIG" \
        "$CAFFEINE_SWIFTPM_SECURITY"

    printf 'Using macOS SDK: %s\n' "$SDKROOT"
}
