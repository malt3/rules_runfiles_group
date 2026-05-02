"""Library for consuming and transforming RunfilesGroupInfo.

lib.group_names(runfiles_group_info)
    Returns the list of group names in a RunfilesGroupInfo instance.

lib.ordered_groups(runfiles_group_info, metadata_info = None)
    Returns a list of (group_name, depset[File]) tuples, ordered by rank
    (ascending). Within the same rank, order is deterministc,
    but consumers should not rely on intra-rank order.

    If metadata_info is None, all groups are included in deterministic order.
    Groups not present in metadata get default rank (0).

lib.transform_groups(runfiles_group_info, metadata_info = None, transform_info = None)
    Applies a transform to (RunfilesGroupInfo, RunfilesGroupMetadataInfo).
    Returns struct(runfiles_group_info, runfiles_group_metadata_info).
    If transform_info is None, returns inputs unchanged.

lib.merge_to_limit(runfiles_group_info, metadata_info = None, max_groups, default_weight = 0, merged_group_name = None)
    Merges groups to fit within max_groups. Groups at the same rank
    without do_not_merge may be merged. Lighter groups (by weight) merge first.
    Returns struct(runfiles_group_info, runfiles_group_metadata_info, group_count).
    The caller must check group_count — if it exceeds max_groups, merging could
    not reduce far enough (e.g., due to do_not_merge or groups in different ranks).
    If merged_group_name is set, it is called as
    merged_group_name(lighter_name, lighter_weight, heavier_name, heavier_weight)
    to determine the name of the merged group. If None, the heavier group's name is kept.

lib.merge_metadata(*metadatas)
    Dict-merges any number of RunfilesGroupMetadataInfo instances (or None).
    Returns RunfilesGroupMetadataInfo or None. Per-key last-wins.

lib.collect_groups(deps)
    Extracts RunfilesGroupInfo and RunfilesGroupMetadataInfo from a list of
    dependency targets. For deps providing RunfilesGroupInfo, extracts all
    groups and metadata. For deps without it, collects
    DefaultInfo.default_runfiles.files as ungrouped.
    Returns struct(groups, metadata, ungrouped) where:
      groups: dict[str, depset[File]]
      metadata: RunfilesGroupMetadataInfo or None
      ungrouped: list[depset[File]]
"""

load("@bazel_features//:features.bzl", "bazel_features")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")
load(
    "//runfiles_group/private/providers:runfiles_group_metadata_info.bzl",
    "DEFAULT_METADATA",
    "RunfilesGroupMetadataInfo",
    "group_metadata",
)

# Bazel < 9 includes to_json/to_proto in dir() results for providers.
_PROVIDER_BUILTINS = [] if bazel_features.rules.no_struct_field_denylist else ["to_json", "to_proto"]

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

    return [(name, getattr(runfiles_group_info, name)) for name in ordered]

def _transform_groups(runfiles_group_info, runfiles_group_metadata_info = None, runfiles_transform_info = None):
    if runfiles_transform_info == None:
        return struct(
            runfiles_group_info = runfiles_group_info,
            runfiles_group_metadata_info = runfiles_group_metadata_info,
        )
    return runfiles_transform_info.transform(runfiles_group_info, runfiles_group_metadata_info)

def _effective_weight(entry, default_weight):
    return entry.weight if entry.weight != None else default_weight

def _find_cheapest_pair(groups, meta, default_weight):
    """Finds the cheapest same-rank mergeable pair. Returns (lighter, heavier) or None."""
    by_rank = {}
    for name in groups:
        entry = meta[name]
        if entry.do_not_merge:
            continue
        rank = entry.rank
        if rank not in by_rank:
            by_rank[rank] = []
        by_rank[rank].append(name)

    best_pair = None
    best_cost = None
    for rank, mergeable in by_rank.items():
        if len(mergeable) < 2:
            continue
        weighted = sorted(
            [((_effective_weight(meta[n], default_weight), n)) for n in mergeable],
            key = lambda pair: (pair[0], pair[1]),
        )
        cost = weighted[0][0] + weighted[1][0]
        if best_cost == None or cost < best_cost or (cost == best_cost and rank < best_pair[0]):
            best_pair = (rank, weighted[0][1], weighted[1][1])
            best_cost = cost

    if best_pair == None:
        return None

    lighter_name = best_pair[1]
    heavier_name = best_pair[2]
    if _effective_weight(meta[lighter_name], default_weight) > _effective_weight(meta[heavier_name], default_weight):
        return (heavier_name, lighter_name)
    return (lighter_name, heavier_name)

def _merge_pair(groups, meta, lighter, heavier, default_weight, merged_group_name_fn):
    """Merges lighter into heavier, returns new (groups, meta) dicts."""
    merged_depsets = groups[lighter] + groups[heavier]
    merged_weight = _effective_weight(meta[lighter], default_weight) + \
                    _effective_weight(meta[heavier], default_weight)
    merged_entry = struct(
        rank = meta[heavier].rank,
        do_not_merge = False,
        weight = merged_weight,
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
        flat[name] = ds[0] if len(ds) == 1 else depset(transitive = ds)
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

def _collect_groups(deps):
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
            ungrouped.append(depset(transitive = [dep[DefaultInfo].files, dep[DefaultInfo].default_runfiles.files]))
    return struct(groups = groups, metadata = metadata, ungrouped = ungrouped)

lib = struct(
    group_metadata = group_metadata,
    group_names = _group_names,
    ordered_groups = _ordered_groups,
    transform_groups = _transform_groups,
    merge_to_limit = _merge_to_limit,
    merge_metadata = _merge_metadata,
    collect_groups = _collect_groups,
)
