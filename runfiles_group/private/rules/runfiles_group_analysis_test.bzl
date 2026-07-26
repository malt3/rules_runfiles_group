"""A test verifying that RunfilesGroupInfo returned by a *_binary target is valid.

Each binary is analyzed in two configurations via a split transition: one with the
global switch @rules_runfiles_group//runfiles_group:enabled set to True, where the
groups are checked for completeness, overlap and ordering, and one with it set to
False, where the binary must emit no RunfilesGroupInfo at all.

Usage:

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [
        ":my_binary",
        ":my_other_binary",
    ],
    overlapping_group_behavior = "error",
)
```
"""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("//runfiles_group/private:lib.bzl", "lib")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")
load("//runfiles_group/private/providers:runfiles_group_metadata_info.bzl", "RunfilesGroupMetadataInfo")

_INDENT = "    "

# The global RunfilesGroupInfo on/off switch, in canonical form so it is
# unambiguous inside a transition regardless of the consumer's repo mapping.
_ENABLED_SETTING = str(Label("//runfiles_group:enabled"))

# Split transition keys: each binary under test is analyzed twice, once with
# RunfilesGroupInfo emission enabled and once with it disabled.
_ENABLED_KEY = "runfiles_group_enabled"
_DISABLED_KEY = "runfiles_group_disabled"

def _rgi_split_transition_impl(_settings, attr):
    branches = {_ENABLED_KEY: {_ENABLED_SETTING: True}}

    # The disabled branch analyzes every target in the binary's closure a second
    # time, because the flag lands in BuildOptions.starlarkOptionsMap and is
    # fingerprinted into the configuration key. That is the price of checking the
    # one MUST in the producer contract, so it stays on by default, but it is
    # opt-out for tests over large binaries.
    if attr.check_disabled:
        branches[_DISABLED_KEY] = {_ENABLED_SETTING: False}
    return branches

# Analyze every binary under test in both configurations, so a single test
# target checks both that the groups are well formed when the providers are
# requested and that the rule honors the global switch when they are not.
# Pinning both branches explicitly also makes the test independent of whatever
# value the flag happens to have on the command line.
_rgi_split_transition = transition(
    implementation = _rgi_split_transition_impl,
    inputs = [],
    outputs = [_ENABLED_SETTING],
)

def _indent(text):
    return "\n".join([_INDENT + line for line in text.split("\n")])

def _get_files(rf):
    return rf.files

def _get_empty_filenames(rf):
    return rf.empty_filenames

def _get_symlinks(rf):
    return rf.symlinks

def _get_root_symlinks(rf):
    return rf.root_symlinks

_RUNFILES_COMPONENTS = [
    ("files", _get_files),
    ("empty_filenames", _get_empty_filenames),
    ("symlinks", _get_symlinks),
    ("root_symlinks", _get_root_symlinks),
]

def _join_group_names(lighter_name, _lighter_weight, heavier_name, _heavier_weight):
    return lib.name_str(lighter_name) + "+" + lib.name_str(heavier_name)

def _make_join_group_names(prefix):
    def _join(lighter_name, _lighter_weight, heavier_name, _heavier_weight):
        stripped = lib.name_str(heavier_name)
        if stripped.startswith(prefix):
            stripped = stripped[len(prefix):]
        return lib.name_str(lighter_name) + "+" + stripped

    return _join

def _test_one(ctx, binary_attr):
    issues = []
    success = True
    default_info = binary_attr[DefaultInfo]
    default_runfiles = default_info.default_runfiles

    # lib.resolve() also validates every entry and that executable_group names a
    # surviving group, so a malformed provider fails here with the binary's label
    # rather than inside somebody's packaging rule.
    resolved = lib.resolve(ctx, binary_attr, aspect_hints = [])
    if resolved == None:
        return (False, [
            "doesn't provide RunfilesGroupInfo even though {} is True.".format(_ENABLED_SETTING),
        ])
    if default_runfiles == None:
        return (False, ["doesn't have default_runfiles to compare to."])

    check_overlap = ctx.attr.overlapping_group_behavior != "ignore"

    # Materialized once per group, outside the per-component loop: a group whose
    # contents are a files-only depset has no symlinks, root symlinks or empty
    # filenames to read, and lib.runfiles() is what turns "no symlinks" into the
    # empty depsets the comparison below needs. Doing it inside the loop would build
    # four runfiles objects per group instead of one.
    groups = [
        (lib.name_str(entry.name), lib.runfiles(ctx, entry))
        for entry in resolved.groups
    ]

    # Note: the following calculations are expensive.
    # This analysis test is only meant to be used to test the correctness of
    # RunfilesGroupInfo emitting rules. Do not use for all of your *_binary targets in prod.
    for component_name, get_depset in _RUNFILES_COMPONENTS:
        all_default = sets.make(get_depset(default_runfiles).to_list())
        all_grouped = sets.make()

        # Overlap is detected in the same pass, by remembering the first group that
        # claimed each entry. Intersecting every pair of groups instead meant
        # flattening and re-hashing every group O(G) times.
        first_owner = {}
        overlaps = {}  # (first owner, other group) -> [entries]

        # `group` is the canonical string form, so the diagnostics read the same
        # whether a group is identified by a Label or by a name.
        for group, group_runfiles in groups:
            for item in get_depset(group_runfiles).to_list():
                sets.insert(all_grouped, item)
                if not check_overlap:
                    continue
                owner = first_owner.get(item)
                if owner == None:
                    first_owner[item] = group
                    continue
                pair = (owner, group)
                if pair in overlaps:
                    overlaps[pair].append(item)
                else:
                    overlaps[pair] = [item]

        if not sets.is_equal(all_default, all_grouped):
            success = False
            missing_from_groups = sets.difference(all_default, all_grouped)
            extra_in_groups = sets.difference(all_grouped, all_default)
            if sets.length(missing_from_groups) > 0:
                issues.append(
                    "{} in default_runfiles missing from RunfilesGroupInfo:\n".format(component_name) +
                    "\n".join([_INDENT + str(item) for item in sets.to_list(missing_from_groups)]),
                )
            if sets.length(extra_in_groups) > 0:
                issues.append(
                    "{} in RunfilesGroupInfo missing from default_runfiles:\n".format(component_name) +
                    "\n".join([_INDENT + str(item) for item in sets.to_list(extra_in_groups)]),
                )

        for pair, items in overlaps.items():
            msg = (
                "{}: groups '{}' and '{}' overlap:\n".format(component_name, pair[0], pair[1]) +
                "\n".join([_INDENT + str(item) for item in items])
            )
            if ctx.attr.overlapping_group_behavior == "error":
                success = False
                issues.append(msg)
            else:
                # buildifier: disable=print
                print("WARNING [{}]: {}".format(binary_attr.label, msg))

    # Apply the optional group limit and check the resulting names and count.
    if ctx.attr.max_groups >= 0:
        join_fn = _make_join_group_names(ctx.attr.group_name_prefix) if ctx.attr.group_name_prefix else _join_group_names
        resolved = lib.limit(
            ctx,
            resolved,
            max_groups = ctx.attr.max_groups,
            merged_group_name = join_fn,
        )
        if ctx.attr.expected_group_count >= 0:
            if resolved.group_count != ctx.attr.expected_group_count:
                success = False
                issues.append(
                    "expected {} groups after merging but got {}".format(
                        ctx.attr.expected_group_count,
                        resolved.group_count,
                    ),
                )
        elif resolved.group_count > ctx.attr.max_groups:
            success = False
            issues.append(
                "max_groups={} requested but merging could only reduce to {} groups".format(
                    ctx.attr.max_groups,
                    resolved.group_count,
                ),
            )

    # Expectations are written as strings in BUILD files, so both name forms are
    # compared in their canonical string form.
    actual_names = [lib.name_str(entry.name) for entry in resolved.groups]
    if ctx.attr.expected_group_names:
        if actual_names != ctx.attr.expected_group_names:
            success = False
            issues.append(
                "expected ordered group names:\n" +
                _INDENT + str(ctx.attr.expected_group_names) + "\n" +
                "actual ordered group names:\n" +
                _INDENT + str(actual_names),
            )

    actual_executable_group = lib.name_str(resolved.executable_group) if resolved.executable_group != None else None
    if ctx.attr.expected_executable_group and actual_executable_group != ctx.attr.expected_executable_group:
        success = False
        issues.append("expected executable_group '{}' but got {}".format(
            ctx.attr.expected_executable_group,
            repr(actual_executable_group),
        ))

    return (success, issues)

def _test_one_disabled(binary_attr):
    """Checks that a binary emits no runfiles group providers when the switch is off."""
    leaked = []
    if RunfilesGroupInfo in binary_attr:
        leaked.append("RunfilesGroupInfo")
    if RunfilesGroupMetadataInfo in binary_attr:
        leaked.append("RunfilesGroupMetadataInfo")
    if len(leaked) == 0:
        return (True, [])
    return (False, [
        ("still provides {} even though {} is False.\n" +
         "Gate emission on lib.is_enabled(ctx) (and merge lib.RULE_ATTRS into the rule's attrs).").format(
            " and ".join(leaked),
            _ENABLED_SETTING,
        ),
    ])

def _runfiles_group_analysis_test_impl(ctx):
    # The binaries attribute uses a split transition, so each entry appears once
    # per branch: with RunfilesGroupInfo emission enabled and with it disabled.
    enabled_binaries = ctx.split_attr.binaries.get(_ENABLED_KEY, [])
    disabled_binaries = ctx.split_attr.binaries.get(_DISABLED_KEY, [])

    if len(enabled_binaries) == 0:
        return [AnalysisTestResultInfo(
            success = False,
            message = "runfiles_group_analysis_test with no binaries.",
        )]

    results = []
    for binary_attr in enabled_binaries:
        results.append((binary_attr.label, "enabled", _test_one(ctx, binary_attr)))
    for binary_attr in disabled_binaries:
        results.append((binary_attr.label, "disabled", _test_one_disabled(binary_attr)))

    success = True
    sections = []
    for label, config, result in results:
        if not result[0]:
            success = False
            if len(result[1]) > 0:
                sections.append(
                    "Issues with {} [{} = {}]:\n{}".format(
                        label,
                        _ENABLED_SETTING,
                        "True" if config == "enabled" else "False",
                        "\n".join([_indent(issue) for issue in result[1]]),
                    ),
                )

    return [AnalysisTestResultInfo(
        success = success,
        message = "\n".join(sections),
    )]

runfiles_group_analysis_test = rule(
    implementation = _runfiles_group_analysis_test_impl,
    doc = """\
Checks that RunfilesGroupInfo is well formed by comparing all runfiles components
(files, empty_filenames, symlinks, root_symlinks) of DefaultInfo.default_runfiles
with the union of all runfiles from RunfilesGroupInfo.

Resolving the provider also validates every group entry and that executable_group,
if set, names a surviving group.

Additionally, it can warn about entries appearing in multiple groups (overlapping),
verify the expected ordered group names, verify which group carries the executable,
and optionally apply merge-to-limit before ordering.

Every binary is analyzed in two configurations via a split transition, so one test
target also verifies that the rule honors the global on/off switch
(@rules_runfiles_group//runfiles_group:enabled):

  * enabled: all of the checks above run against the emitted providers.
  * disabled: the binary must provide neither RunfilesGroupInfo nor
    RunfilesGroupMetadataInfo. Set check_disabled = False to skip this branch,
    which avoids analyzing the binary's whole closure a second time.

Because both branches are pinned by the transition, the test is independent of the
value the flag has on the command line.
""",
    attrs = {
        "binaries": attr.label_list(
            cfg = _rgi_split_transition,
            mandatory = True,
            doc = "List of *_binary targets to test.",
        ),
        "check_disabled": attr.bool(
            default = True,
            doc = """\
Also analyze every binary with @rules_runfiles_group//runfiles_group:enabled set
to False and verify it emits neither RunfilesGroupInfo nor
RunfilesGroupMetadataInfo.

This is the only automated check of the producer contract's one MUST, so it is on
by default. It does cost a second configuration for the binary and its entire
transitive closure, so set it to False on tests over large binaries and keep one
small target that checks it. Must not be a select().
""",
        ),
        "expected_group_names": attr.string_list(
            doc = """\
If set, the test verifies that the ordered group names (after optional merging and rank-based ordering)
match this list exactly. Applies to all binaries in the test.

Names are compared in canonical string form (lib.name_str), so a group named by a Label
is written as its canonical label string, e.g. "@@//src:lib_a".
""",
        ),
        "expected_executable_group": attr.string(
            doc = """\
If set, the test verifies that RunfilesGroupInfo.executable_group (after optional
merging) is exactly this group name, in canonical string form (lib.name_str) -- so a
group named by a Label is written as its canonical label string. Applies to all
binaries in the test.
""",
        ),
        "max_groups": attr.int(
            doc = "If >= 0, apply lib.limit with this limit before ordering. -1 means no limit.",
            default = -1,
        ),
        "expected_group_count": attr.int(
            doc = """\
If >= 0, verify the exact number of groups after merging (requires max_groups >= 0).
Use this when merging cannot reach max_groups (e.g., due to do_not_merge or rank constraints)
to assert the actual reachable count. -1 means no check (the test fails if group_count > max_groups instead).
""",
            default = -1,
        ),
        "group_name_prefix": attr.string(
            doc = """\
If set, merged group names will strip this prefix from the second (heavier) group name
before joining with '+'. This avoids repeating a common prefix in merged names.
For example, with prefix "p#", merging "p#foo" and "p#bar" produces "p#foo+bar" instead of "p#foo+p#bar".
Names are canonicalized first, so this also applies to groups named by a Label.
""",
        ),
        "overlapping_group_behavior": attr.string(
            doc = "How to handle overlapping groups (the same entry being present in more than one group).",
            default = "warn",
            values = ["warn", "ignore", "error"],
        ),
    },
    analysis_test = True,
)
