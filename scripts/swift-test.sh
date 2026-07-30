#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(
    cd "$SCRIPT_DIRECTORY/.." && pwd -P
)"
readonly REPOSITORY_ROOT

# shellcheck source=scripts/swift-sdk.sh
source "$SCRIPT_DIRECTORY/swift-sdk.sh"
caffeine_select_swift_sdk "$REPOSITORY_ROOT"

cd "$REPOSITORY_ROOT"
swift_test_arguments=(
    --sdk "$SDKROOT"
    --arch "$CAFFEINE_HOST_ARCHITECTURE"
    --enable-swift-testing
    --scratch-path "$CAFFEINE_SCRATCH_PATH"
    --disable-sandbox
    --cache-path "$CAFFEINE_SWIFTPM_CACHE"
    --config-path "$CAFFEINE_SWIFTPM_CONFIG"
    --security-path "$CAFFEINE_SWIFTPM_SECURITY"
    --manifest-cache local
    -Xswiftc -module-cache-path
    -Xswiftc "$CAFFEINE_MODULE_CACHE"
    -Xcc "-fmodules-cache-path=$CAFFEINE_CLANG_MODULE_CACHE"
)

if [[ -n "$CAFFEINE_DEVELOPER_FRAMEWORKS" ]]; then
    swift_test_arguments+=(
        -Xswiftc -F
        -Xswiftc "$CAFFEINE_DEVELOPER_FRAMEWORKS"
        -Xlinker "-F$CAFFEINE_DEVELOPER_FRAMEWORKS"
        -Xlinker -rpath
        -Xlinker "$CAFFEINE_DEVELOPER_FRAMEWORKS"
    )
fi
if [[ -n "$CAFFEINE_DEVELOPER_USR_LIB" ]]; then
    swift_test_arguments+=(
        -Xlinker -rpath
        -Xlinker "$CAFFEINE_DEVELOPER_USR_LIB"
    )
fi

exec "$CAFFEINE_SWIFT" test "${swift_test_arguments[@]}"
