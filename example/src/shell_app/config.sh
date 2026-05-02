#!/usr/bin/env bash

GREETING_PREFIX="Hello"

load_config() {
  local config_file
  config_file="$(rlocation _main/src/shell_app/data/defaults.conf)"
  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi
}
