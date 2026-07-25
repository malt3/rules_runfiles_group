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
    """
    best = None  # (cost, rank, lighter_name, heavier_name)
    for _key, names in buckets.items():
        if len(names) < 2:
            continue
        weighted = sorted(
            [(_effective_weight(meta[n], default_weight), n) for n in names],
            key = lambda pair: (pair[0], pair[1]),
        )
        lighter_name = weighted[0][1]
        heavier_name = weighted[1][1]
        cost = weighted[0][0] + weighted[1][0]
        candidate = (cost, meta[lighter_name].rank, lighter_name, heavier_name)
        if best == None or candidate < best:
            best = candidate
    if best == None:
        return None
    return (best[2], best[3])

def _find_cheapest_pair(groups, meta, default_weight):
    """Finds the best same-rank mergeable pair. Returns (lighter, heavier) or None.

    Prefers pairs that share the same merge_affinity (the empty string "" is the
    shared "no affinity" bucket). Among the preferred pairs the cheapest (lowest
    combined weight) wins. Only when no same-affinity pair exists at any rank
    does it fall back to merging the cheapest same-rank pair regardless of
    affinity.
    """
    mergeable = [name for name in groups if not meta[name].do_not_merge]

    # Tier 1: prefer merging groups that share the same (rank, merge_affinity).
    by_rank_affinity = {}
    for name in mergeable:
        key = (meta[name].rank, meta[name].merge_affinity)
        if key not in by_rank_affinity:
            by_rank_affinity[key] = []
        by_rank_affinity[key].append(name)
    pair = _cheapest_pair_in_buckets(by_rank_affinity, meta, default_weight)
    if pair != None:
        return pair

    # Tier 2: fall back to the cheapest same-rank pair across affinities.
    by_rank = {}
    for name in mergeable:
        rank = meta[name].rank
        if rank not in by_rank:
            by_rank[rank] = []
        by_rank[rank].append(name)
    return _cheapest_pair_in_buckets(by_rank, meta, default_weight)

def _merge_pair(groups, meta, lighter, heavier, default_weight, merged_group_name_fn):
    """Merges lighter into heavier, returns new (groups, meta) dicts."""
    merged_depsets = groups[lighter] + groups[heavier]
    merged_weight = _effective_weight(meta[lighter], default_weight) + \
                    _effective_weight(meta[heavier], default_weight)
    merged_entry = struct(
        rank = meta[heavier].rank,
        do_not_merge = False,
        weight = merged_weight,
        executable_group = meta[lighter].executable_group or meta[heavier].executable_group,
        merge_affinity = meta[heavier].merge_affinity,
    )

    if merged_group_name_fn != None:
        lighter_w = _effective_weight(meta[lighter], default_weight)
        heavier_w = _effective_weight(meta[heavier], default_weight)
        out_name = merged_group_name_fn(lighter, lighter_w, heavier, heavier_w)
    else:
        out_name = heavier

    new_groups = {n: d for n, d in groups.items() if n != lighter and n != heavier}
    new_groups[out_name] = merged_depsets
    new_meta = {n: e for n, e in meta.items() if n != lighter and n != heavier}
    new_meta[out_name] = merged_entry
    return (new_groups, new_meta)

def _merge_to_limit(runfiles_group_info, runfiles_group_metadata_info = None, *, max_groups, default_weight = 0, merged_group_name = None):
    names = _group_names(runfiles_group_info)
    if len(names) <= max_groups:
        return struct(
            runfiles_group_info = runfiles_group_info,
            runfiles_group_metadata_info = runfiles_group_metadata_info,
            group_count = len(names),
        )

    groups = {name: [getattr(runfiles_group_info, name)] for name in names}
    meta = {}
    for name in names:
        meta[name] = _get_metadata(runfiles_group_metadata_info, name)

    for _ in range(len(names)):
        if len(groups) <= max_groups:
            break
        pair = _find_cheapest_pair(groups, meta, default_weight)
        if pair == None:
            break
        groups, meta = _merge_pair(groups, meta, pair[0], pair[1], default_weight, merged_group_name)

    flat = {}
    for name, ds in groups.items():
        flat[name] = ds[0] if len(ds) == 1 else ds[0].merge_all(ds[1:])
    merged_rgi = RunfilesGroupInfo(**flat)
    merged_metadata = RunfilesGroupMetadataInfo(groups = meta) if meta else runfiles_group_metadata_info
    return struct(
        runfiles_group_info = merged_rgi,
        runfiles_group_metadata_info = merged_metadata,
        group_count = len(groups),
    )

def _merge_metadata(*metadatas):
    result = None
    for m in metadatas:
        if m == None:
            continue
        if result == None:
            result = m
        else:
            merged = dict(result.groups)
            merged.update(m.groups)
            result = RunfilesGroupMetadataInfo(groups = merged)
    return result

def _collect_groups(ctx, deps, *, strip_executable_group = True):
    groups = {}
    metadata = None
    ungrouped = []
    for dep in deps:
        if RunfilesGroupInfo in dep:
            for name in _group_names(dep[RunfilesGroupInfo]):
                groups[name] = getattr(dep[RunfilesGroupInfo], name)
            if RunfilesGroupMetadataInfo in dep:
                metadata = _merge_metadata(metadata, dep[RunfilesGroupMetadataInfo])
        else:
            ungrouped.append(("data#" + str(dep.label), dep))
    for group_name, dep in ungrouped:
        groups[group_name] = ctx.runfiles(
            transitive_files = dep[DefaultInfo].files,
        ).merge_all([dep[DefaultInfo].default_runfiles])
    if strip_executable_group and metadata != None:
        needs_strip = False
        for entry in metadata.groups.values():
            if entry.executable_group:
                needs_strip = True
                break
        if needs_strip:
            stripped = {}
            for name, entry in metadata.groups.items():
                if entry.executable_group:
                    stripped[name] = group_metadata(
                        rank = entry.rank,
                        do_not_merge = entry.do_not_merge,
                        weight = entry.weight,
                        merge_affinity = entry.merge_affinity,
                    )
                else:
                    stripped[name] = entry
            metadata = RunfilesGroupMetadataInfo(groups = stripped)
    return struct(groups = groups, metadata = metadata)

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
