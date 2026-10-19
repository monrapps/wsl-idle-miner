#!/bin/bash
set -euo pipefail
project_dir="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$project_dir/idle-miner.ps1")" -Action "${1:-Status}" "${@:2}"
