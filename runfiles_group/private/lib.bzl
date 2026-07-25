"""Library for consuming and transforming RunfilesGroupInfo.

lib.group_names(runfiles_group_info)
    Returns the list of group names in a RunfilesGroupInfo instance.

lib.ordered_groups(runfiles_group_info, metadata_info = None)
    Returns a list of struct(name, runfiles, metadata) entries, ordered by rank
    (ascending). name is the group name (string), runfiles is a runfiles object,
    and metadata is the group_metadata struct (or None if no explicit
    metadata exists for that group).

    Within the same rank, order is deterministc,
    but consumers should not rely on intra-rank order.

    If metadata_info is None, all groups are included in deterministic order
    with metadata set to None.
    Groups not present in metadata get None as metadata.

lib.transform_groups(runfiles_group_info, metadata_info = None, transform_info = None)
    Applies a transform to (RunfilesGroupInfo, RunfilesGroupMetadataInfo).
    Returns struct(runfiles_group_info, runfiles_group_metadata_info).
    If transform_info is None, returns inputs unchanged.

lib.merge_to_limit(runfiles_group_info, metadata_info = None, max_groups, default_weight = 0, merged_group_name = None)
    Merges groups to fit within max_groups. Groups at the same rank
    without do_not_merge may be merged. Merging prefers pairs that share the
    same merge_affinity (the empty string "" is the shared "no affinity"
    bucket); only when no same-affinity pair remains does it fall back to
    merging across affinities. Within the preferred set, lighter groups
    (by weight) merge first.
    Returns struct(runfiles_group_info, runfiles_group_metadata_info, group_count).
    The caller must check group_count — if it exceeds max_groups, merging could
    not reduce far enough (e.g., due to do_not_merge or groups in different ranks).
    If merged_group_name is set, it is called as
    merged_group_name(lighter_name, lighter_weight, heavier_name, heavier_weight)
    to determine the name of the merged group. If None, the heavier group's name is kept.

lib.merge_metadata(*metadatas)
    Dict-merges any number of RunfilesGroupMetadataInfo instances (or None).
    Returns RunfilesGroupMetadataInfo or None. Per-key last-wins.

lib.collect_groups(ctx, deps, *, strip_executable_group = True)
    Extracts RunfilesGroupInfo and RunfilesGroupMetadataInfo from a list of
    dependency targets. For deps providing RunfilesGroupInfo, extracts all
    groups and metadata. For deps without it, creates a named group
    "data#<canonical label>" whose value is a runfiles object combining
    DefaultInfo.files and DefaultInfo.default_runfiles. This means that if
    two parts of the dependency graph share the same data dep, they produce
    the same group name — the binary-level dict merge naturally deduplicates
    the group so the files are recorded only once.
    Auto-generated "data#<label>" groups carry no metadata, so they take the
    default empty merge_affinity ("") — a data dep that does not itself provide
    RunfilesGroupInfo is never assigned an affinity.
    If strip_executable_group is True (default), the executable_group bit
    is cleared on all collected metadata entries. This is the correct
    default when collecting from data deps: the executable_group annotation
    is only meaningful for the top-level *_binary target, not for binaries
    that appear as data dependencies of another binary.
    Returns struct(groups, metadata) where:
      groups: dict[str, runfiles]
      metadata: RunfilesGroupMetadataInfo or None

lib.RULE_ATTRS
    Attribute fragment that *_binary / *_library rule authors merge into their
    rule's attrs to gain access to the global RunfilesGroupInfo on/off switch
    (@rules_runfiles_group//runfiles_group:enabled). Paired with lib.is_enabled:
    a rule that calls lib.is_enabled(ctx) MUST have merged lib.RULE_ATTRS into
    its attrs, or the read will fail.

lib.is_enabled(ctx)
    Returns whether RunfilesGroupInfo emission is globally enabled, reading the
    @rules_runfiles_group//runfiles_group:enabled build setting (default False).
    Rules should gate provider emission on this and emit no RunfilesGroupInfo
    when it returns False. Requires lib.RULE_ATTRS to have been merged into the
    rule's attrs.

lib.RANK_FOUNDATION / lib.RANK_SHARED_DEPS / lib.RANK_EXECUTABLE
    Recommended rank anchors for group_metadata(rank = ...). Foundational
    content (runtimes, interpreters, standard libraries) anchors at
    RANK_FOUNDATION (-1000), shared third-party dependencies at
    RANK_SHARED_DEPS (-100), and the executable / first-party code at
    RANK_EXECUTABLE (0, the default). The anchors are spaced far apart so
    finer sub-tiers can be slotted in between. See the README for details.
"""

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")
load(
    "//runfiles_group/private/providers:runfiles_group_metadata_info.bzl",
    "DEFAULT_METADATA",
    "RunfilesGroupMetadataInfo",
    "group_metadata",
)

# Bazel < 9 includes to_json/to_proto in dir() results for providers.
_PROVIDER_BUILTINS = [] if bazel_features.rules.no_struct_field_denylist else ["to_json", "to_proto"]

# Recommended rank anchors (see README "Recommended rank values").
#
# Ranks form a partial order: lower rank = earlier layer = changes least often.
# These anchors are spaced far apart on purpose so rule authors can slot extra
# sub-tiers in between (e.g. an interpreter at RANK_FOUNDATION and a standard
# library at RANK_FOUNDATION + 100) without renumbering everything.
#
# - RANK_FOUNDATION (-1000): foundational, rarely-changing content shared by
#   many binaries — language runtimes, interpreters, standard libraries.
# - RANK_SHARED_DEPS (-100): third-party dependencies shared across binaries.
# - RANK_EXECUTABLE (0): the executable and first-party application code. This
#   is also the default rank for groups without explicit metadata.
_RANK_FOUNDATION = -1000
_RANK_SHARED_DEPS = -100
_RANK_EXECUTABLE = 0

def _group_names(runfiles_group_info):
    """Returns the list of group names in a RunfilesGroupInfo instance."""
    return [n for n in dir(runfiles_group_info) if n not in _PROVIDER_BUILTINS]

def _get_metadata(metadata_info, name):
    if metadata_info == None:
        return DEFAULT_METADATA
    return metadata_info.groups.get(name, DEFAULT_METADATA)

def _ordered_groups(runfiles_group_info, runfiles_group_metadata_info = None):
    all_names = _group_names(runfiles_group_info)

    if runfiles_group_metadata_info == None:
        ordered = sorted(all_names)
    else:
        ordered = sorted(
            all_names,
            key = lambda name: (
                _get_metadata(runfiles_group_metadata_info, name).rank,
                name,
            ),
        )

    return [
        struct(
            name = name,
            runfiles = getattr(runfiles_group_info, name),
            metadata = (
                runfiles_group_metadata_info.groups[name] if runfiles_group_metadata_info != None and name in runfiles_group_metadata_info.groups else None
            ),
        )
        for name in ordered
    ]

def _transform_groups(runfiles_group_info, runfiles_group_metadata_info = None, runfiles_transform_info = None):
    if runfiles_transform_info == None:
        return struct(
            runfiles_group_info = runfiles_group_info,
            runfiles_group_metadata_info = runfiles_group_metadata_info,
        )
    return runfiles_transform_info.transform(runfiles_group_info, runfiles_group_metadata_info)

def _effective_weight(entry, default_weight):
    return entry.weight if entry.weight != None else default_weight

def _cheapest_pair_in_buckets(buckets, meta, default_weight):
    """Returns the cheapest 2-lightest mergeable pair across all buckets.

    Given a dict of bucket_key -> [group names], returns the pair as
    (lighter, heavier), or None. Cost is the combined effective weight of the
    two lightest groups in a bucket. Ties are broken deterministically by
    (cost, rank, lighter, heavier).

    The two lightest are found with a linear two-minimum scan rather than by
    sorting the bucket: this runs once per merge step, and sorting allocated a
    decorator array, a key tuple and a Starlark frame per element per step.
    """
    best = None  # (cost, rank, lighter_name, heavier_name)
    for _key, names in buckets.items():
        if len(names) < 2:
            continue
        w1 = None
        n1 = None
        w2 = None
        n2 = None
        for name in names:
            entry = meta.get(name)
            if entry == None:
                continue  # merged away in an earlier step
            w = _effective_weight(entry, default_weight)
            if n1 == None or w < w1 or (w == w1 and name < n1):
                w2 = w1
                n2 = n1
                w1 = w
                n1 = name
            elif n2 == None or w < w2 or (w == w2 and name < n2):
                w2 = w
                n2 = name
        if n2 == None:
            continue
        candidate = (w1 + w2, meta[n1].rank, n1, n2)
        if best == None or candidate < best:
            best = candidate
    if best == None:
        return None
    return (best[2], best[3])

def _bucket_add(buckets, key, name):
    bucket = buckets.get(key)
    if bucket == None:
        buckets[key] = [name]
    else:
        bucket.append(name)

def _bucket_remove(buckets, key, name):
    bucket = buckets.get(key)
    if bucket != None and name in bucket:
        bucket.remove(name)

def _affinity_key(entry):
    return (entry.rank, entry.merge_affinity)

def _merge_to_limit(runfiles_group_info, runfiles_group_metadata_info = None, *, max_groups, default_weight = 0, merged_group_name = None):
    names = _group_names(runfiles_group_info)
    if len(names) <= max_groups:
        return struct(
            runfiles_group_info = runfiles_group_info,
            runfiles_group_metadata_info = runfiles_group_metadata_info,
            group_count = len(names),
        )

    meta = {}
    for name in names:
        meta[name] = _get_metadata(runfiles_group_metadata_info, name)

    # Runfiles are collected per surviving group and merged with a single
    # merge_all() at the end. A pairwise fold would retain one two-slot array per
    # step (NestedSet.create stores a child's array, not the child node) and
    # deepen the artifact DAG once per merge.
    runfiles = {name: getattr(runfiles_group_info, name) for name in names}
    parts = {}  # group name -> [runfiles], only for groups that actually merged

    # Buckets are built once and patched incrementally: only the two merged
    # groups and their replacement change, so rebuilding and re-sorting every
    # bucket on every step was pure waste.
    by_rank_affinity = {}
    by_rank = {}
    for name, entry in meta.items():
        if entry.do_not_merge:
            continue
        _bucket_add(by_rank_affinity, _affinity_key(entry), name)
        _bucket_add(by_rank, entry.rank, name)

    for _ in range(len(names)):
        if len(meta) <= max_groups:
            break

        # Tier 1: prefer merging groups that share the same (rank, affinity).
        # Tier 2: fall back to the cheapest same-rank pair across affinities.
        pair = _cheapest_pair_in_buckets(by_rank_affinity, meta, default_weight)
        if pair == None:
            pair = _cheapest_pair_in_buckets(by_rank, meta, default_weight)
        if pair == None:
            break

        lighter, heavier = pair
        light = meta.pop(lighter)
        heavy = meta.pop(heavier)
        _bucket_remove(by_rank_affinity, _affinity_key(light), lighter)
        _bucket_remove(by_rank_affinity, _affinity_key(heavy), heavier)
        _bucket_remove(by_rank, light.rank, lighter)
        _bucket_remove(by_rank, heavy.rank, heavier)

        light_weight = _effective_weight(light, default_weight)
        heavy_weight = _effective_weight(heavy, default_weight)
        if merged_group_name != None:
            out_name = merged_group_name(lighter, light_weight, heavier, heavy_weight)
            if type(out_name) != "string" or not out_name:
                fail("merge_to_limit: merged_group_name must return a non-empty string, got ", type(out_name))

            # Silently overwriting a third, untouched group would drop its
            # runfiles and violate its do_not_merge.
            if out_name in meta:
                fail("merge_to_limit: merged_group_name('{}', '{}') returned '{}', which is an existing group".format(
                    lighter,
                    heavier,
                    out_name,
                ))
        else:
            out_name = heavier

        acc = parts.pop(heavier, None)
        if acc == None:
            acc = [runfiles.pop(heavier)]
        light_parts = parts.pop(lighter, None)
        if light_parts == None:
            acc.append(runfiles.pop(lighter))
        else:
            acc.extend(light_parts)
        parts[out_name] = acc

        merged_entry = struct(
            rank = heavy.rank,
            do_not_merge = False,
            weight = light_weight + heavy_weight,
            executable_group = light.executable_group or heavy.executable_group,
            merge_affinity = heavy.merge_affinity,
        )
        meta[out_name] = merged_entry
        _bucket_add(by_rank_affinity, _affinity_key(merged_entry), out_name)
        _bucket_add(by_rank, merged_entry.rank, out_name)

    for name, acc in parts.items():
        runfiles[name] = acc[0] if len(acc) == 1 else acc[0].merge_all(acc[1:])

    return struct(
        runfiles_group_info = RunfilesGroupInfo(**runfiles),
        runfiles_group_metadata_info = RunfilesGroupMetadataInfo(groups = meta) if meta else runfiles_group_metadata_info,
        group_count = len(runfiles),
    )

def _merge_metadata(*metadatas):
    """Dict-merges RunfilesGroupMetadataInfo instances. Per-key last-wins.

    Allocates one dict and one provider regardless of arity, and returns the sole
    non-None argument by identity. Building one of each per argument meant every
    extra dep re-copied and re-validated the whole accumulated dict.
    """
    first = None
    merged = None
    for m in metadatas:
        if m == None:
            continue
        if merged != None:
            merged.update(m.groups)
        elif first == None:
            first = m
        else:
            merged = dict(first.groups)
            merged.update(m.groups)
    if merged == None:
        return first
    return RunfilesGroupMetadataInfo(groups = merged)

def _collect_groups(ctx, deps, *, strip_executable_group = True):
    groups = {}
    meta = {}
    has_metadata = False
    ungrouped = []
    for dep in deps:
        if RunfilesGroupInfo in dep:
            runfiles_group_info = dep[RunfilesGroupInfo]
            for name in _group_names(runfiles_group_info):
                groups[name] = getattr(runfiles_group_info, name)
            if RunfilesGroupMetadataInfo in dep:
                has_metadata = True

                # Entries are carried over by identity, so a dep's metadata
                # structs are shared rather than rebuilt at every level.
                meta.update(dep[RunfilesGroupMetadataInfo].groups)
        else:
            ungrouped.append(dep)
    for dep in ungrouped:
        # Read DefaultInfo once: every access on a target that does not return it
        # explicitly constructs a fresh DelegatingDefaultInfo, and every .files
        # read a fresh depset wrapper.
        default_info = dep[DefaultInfo]
        runfiles = default_info.default_runfiles

        # default_runfiles is None for a rule that set only data_runfiles.
        if runfiles == None:
            runfiles = ctx.runfiles()
        files = default_info.files

        # Truth-testing a depset is O(1). Skipping the wrapper for a dep that
        # contributes no files avoids a runfiles object and a nested set per
        # (target, data dep) edge, retained for the life of the provider.
        if files:
            runfiles = ctx.runfiles(transitive_files = files).merge(runfiles)
        groups["data#" + str(dep.label)] = runfiles
    if strip_executable_group and has_metadata:
        # Patch only the flagged entries. Rebuilding the whole dict would also
        # de-share every entry that did not need changing.
        flagged = [name for name, entry in meta.items() if entry.executable_group]
        for name in flagged:
            entry = meta[name]
            meta[name] = group_metadata(
                rank = entry.rank,
                do_not_merge = entry.do_not_merge,
                weight = entry.weight,
                merge_affinity = entry.merge_affinity,
            )
    return struct(
        groups = groups,
        metadata = RunfilesGroupMetadataInfo(groups = meta) if has_metadata else None,
    )


# Attribute fragment consumers merge into their rule's attrs to read the global
# RunfilesGroupInfo on/off switch. Paired with is_enabled(ctx): a rule that
# calls lib.is_enabled(ctx) must have merged lib.RULE_ATTRS into its attrs.
#
# Label("//runfiles_group:enabled") is resolved in this module's repo context,
# so it points at @rules_runfiles_group//runfiles_group:enabled in every
# consumer repo — consumers merge in this fragment without naming the flag.
RULE_ATTRS = {
    "_runfiles_group_enabled": attr.label(default = Label("//runfiles_group:enabled")),
}

def _is_enabled(ctx):
    """Returns whether RunfilesGroupInfo emission is globally enabled.

    Reads the @rules_runfiles_group//runfiles_group:enabled build setting.
    Requires lib.RULE_ATTRS to have been merged into the rule's attrs.
    """
    return ctx.attr._runfiles_group_enabled[BuildSettingInfo].value

lib = struct(
    group_metadata = group_metadata,
    group_names = _group_names,
    ordered_groups = _ordered_groups,
    transform_groups = _transform_groups,
    merge_to_limit = _merge_to_limit,
    merge_metadata = _merge_metadata,
    collect_groups = _collect_groups,
    # Global on/off switch (see //runfiles_group:enabled). RULE_ATTRS and
    # is_enabled are a pair — see their docs above.
    RULE_ATTRS = RULE_ATTRS,
    is_enabled = _is_enabled,
    # Recommended rank anchors (see README "Recommended rank values").
    RANK_FOUNDATION = _RANK_FOUNDATION,
    RANK_SHARED_DEPS = _RANK_SHARED_DEPS,
    RANK_EXECUTABLE = _RANK_EXECUTABLE,
)
