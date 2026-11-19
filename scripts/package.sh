#!/bin/zsh
set -euo pipefail
repo_root=${0:A:h:h}
temp_root=${TMPDIR:-/tmp}
stage=$(mktemp -d "${temp_root%/}/codex-subrouter-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Codex SubRouter.app"
"$repo_root/scripts/build.sh" "$bundle"
python3 "$repo_root/scripts/package.py" "$bundle"
