#!/usr/bin/env bash
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

# shellcheck disable=SC1090
source "$(rlocation _main/src/shell_app/config.sh)"
# shellcheck disable=SC1090
source "$(rlocation _main/src/shell_app/format.sh)"

load_config

names_file="$(rlocation _main/src/shell_app/data/names.txt)"
while IFS= read -r name; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  format_greeting "$name" "$GREETING_PREFIX"
done < "$names_file"

banner_file="$(rlocation _main/src/shell_app/templates/banner.txt)"
print_banner "$banner_file"
