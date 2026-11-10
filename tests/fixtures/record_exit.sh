#!/usr/bin/env bash
set -euo pipefail
receipt="$1"
shift
if "$@"; then status=0; else status=$?; fi
printf 'exit:%d:done\n' "$status" > "$receipt"
exit "$status"
