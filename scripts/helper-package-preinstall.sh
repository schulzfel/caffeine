#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIRECTORY="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P
)"
readonly SCRIPT_DIRECTORY

# shellcheck source=scripts/helper-package-common.sh
source "$SCRIPT_DIRECTORY/helper-package-common.sh"

[[ "$#" -ge 3 ]] ||
    caffeine_package_fail "invalid macOS Installer script arguments"
caffeine_package_preflight "$3"
