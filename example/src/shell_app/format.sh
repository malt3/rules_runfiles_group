#!/usr/bin/env bash

format_greeting() {
  local name="$1"
  local prefix="$2"
  echo "${prefix} ${name}!"
}

print_banner() {
  local banner_file="$1"
  if [[ -f "$banner_file" ]]; then
    echo ""
    cat "$banner_file"
  fi
}
