#!/usr/bin/env bash
# Prints `bazel dump --memory=shallow,...` for one configured target.
#
# `shallow` reports only what is NOT reachable from the node's direct deps -- close
# enough to "what this target's own providers add" to be the number to watch: it
# must not grow with the size of the transitive closure.
#
# It measures a *rule's* node. RunfilesGroupInfo lives on runfiles_group_aspect's
# node instead, and `bazel dump --memory` accepts only package:,
# configured_target: and starlark_module: -- an aspect node cannot be named. So
# this covers a rule's own providers, not the group entries. See "Keeping analysis
# memory flat" in the README.
#
# Two caveats when reading an absolute figure. Interned values (String, Label) are
# re-billed to every node that reaches them, so a node's total includes interned
# values its dependencies own -- which is why a binary that re-derives one entry per
# transitive target is charged for all their Labels. And a String is billed a flat
# 24 bytes, because the dumper does not traverse the backing array.
#
# The configuration hash is mandatory in practice. `bazel dump` defaults to the
# configuration of the *dump* command, which is not the one the preceding
# `build` used, so the node is reported as absent. `bazel cquery` both analyzes
# the target (putting it in the graph) and prints the checksum prefix of the
# configuration it was analyzed in, so this script is self-contained.
#
# Usage: tools/shallow_bytes.sh <label> [display-mode]
#   display-mode: summary (default) | bytes | count
#
# Run from the workspace that contains the target, e.g.
#   ../tools/shallow_bytes.sh //stress:chain250_lib249
set -euo pipefail

label="${1:?usage: shallow_bytes.sh <label> [summary|bytes|count]}"
mode="${2:-summary}"

cquery_out="$(mktemp)"
trap 'rm -f "${cquery_out}"' EXIT
bazel cquery "${label}" >"${cquery_out}" 2>&1

config="$(sed -n 's/.*(\([0-9a-f]*\))$/\1/p' "${cquery_out}" | head -1)"
if [[ -z "${config}" ]]; then
  echo "shallow_bytes.sh: could not determine the configuration of ${label}:" >&2
  cat "${cquery_out}" >&2
  exit 1
fi

# `bazel dump` writes its payload to stderr, so merge the streams and let the
# caller filter. The interleaved INFO/WARNING lines are harmless.
bazel dump "--memory=shallow,${mode},noconfig:configured_target:${label}@${config}" 2>&1
