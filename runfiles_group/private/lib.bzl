"""Library for producing and consuming runfiles groups.

PRODUCER SIDE -- O(1) allocations per target, never flattens anything:

    lib.entry(name, runfiles, kind, rank, do_not_merge, weight, merge_affinity)
        One group entry. The only supported entry constructor.
    lib.derive(entry, **overrides)
        A copy of an entry with some fields changed. Use this instead of
        re-listing every field, which is how a re-ranking producer or a renaming
        transform silently resets the fields it forgot.
    lib.collect(ctx, deps = , data = , own = )
        The whole entry depset for a target: its own entries plus its
        dependencies'. Dependencies that provide RunfilesGroupInfo contribute
        their `entries` by reference; the others get one synthesized
        "data#<label>" entry each.
    lib.entries(direct = , transitive = )
        An entry depset with the order the protocol requires, for producers that
        do not collect from dependencies.

    Then: RunfilesGroupInfo(entries = ..., executable_group = ...)

CONSUMER SIDE -- flatten exactly ONCE per consuming target:

    lib.resolve(source, aspect_hints = )
        THE ONLY to_list() IN THE PROTOCOL. Flattens the entry depset, folds
        duplicate group names, applies the metadata overrides from the target and
        from `aspect_hints`, runs the hint transforms, and orders by (rank, name).
        Returns struct(groups, by_name, executable_group), or None when the source
        carries no groups -- in which case the packager must fall back to
        DefaultInfo.default_runfiles as a single group.
          groups:           list of entries ordered by (rank, name)
          by_name:          dict[str, entry]
          executable_group: str or None, guaranteed to be a key of by_name
    lib.resolved(groups, executable_group = )
        Builds a resolved value from a list of entries. This is what a transform
        returns.
    lib.group_names(resolved)
        Sorted list of group names.
    lib.limit(resolved, max_groups = , default_weight = , merged_group_name = )
        Merges groups until at most max_groups remain, respecting rank,
        do_not_merge, merge_affinity and weight. Returns a resolved value plus
        `group_count`, which the caller MUST check: do_not_merge and rank
        constraints can make max_groups unreachable.
    lib.merge_metadata(*metadata_infos)
        Dict-merges RunfilesGroupMetadataInfo overrides. Per-key last-wins.
    lib.group_metadata(**fields)
        A metadata override patch carrying only the fields passed.

Call lib.resolve() once per *consuming* target, from a non-propagating aspect or a
rule. Never from a *_library rule: lib.collect() is the O(1) call, lib.resolve() is
the O(closure) one.

lib.KINDS / lib.DEFAULT_METADATA
    The closed set of `kind` values and the metadata a group has when nothing
    overrides it.

lib.RULE_ATTRS / lib.is_enabled(ctx)
    A pair. Rule authors merge lib.RULE_ATTRS into their rule's attrs to gain
    access to the global RunfilesGroupInfo on/off switch
    (@rules_runfiles_group//runfiles_group:enabled, default False) and gate
    provider emission on lib.is_enabled(ctx). A rule that calls lib.is_enabled
    MUST have merged lib.RULE_ATTRS, or the read fails.

lib.RANK_FOUNDATION / lib.RANK_SHARED_DEPS / lib.RANK_EXECUTABLE
    Recommended rank anchors. Foundational content (runtimes, interpreters,
    standard libraries) anchors at RANK_FOUNDATION (-1000), shared third-party
    dependencies at RANK_SHARED_DEPS (-100), and the executable / first-party code
    at RANK_EXECUTABLE (0, the default). The anchors are spaced far apart so finer
    sub-tiers can be slotted in between. See the README for details.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//runfiles_group/private/providers:runfiles_group_entry_info.bzl", "KINDS", "RunfilesGroupEntryInfo")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")
load(
    "//runfiles_group/private/providers:runfiles_group_metadata_info.bzl",
    "DEFAULT_METADATA",
    "ENTRY_PATCH_FIELDS",
    "RunfilesGroupMetadataInfo",
    "group_metadata",
)
load("//runfiles_group/private/providers:runfiles_group_transform_info.bzl", "RunfilesGroupTransformInfo")

# Recommended rank anchors (see README "Recommended rank values").
#
# Ranks form a partial order: lower rank = earlier layer = changes least often.
# These anchors are spaced far apart on purpose so rule authors can slot extra
# sub-tiers in between (e.g. an interpreter at RANK_FOUNDATION and a standard
# library at RANK_FOUNDATION + 100) without renumbering everything.
_RANK_FOUNDATION = -1000
_RANK_SHARED_DEPS = -100
_RANK_EXECUTABLE = 0

# A module-level string literal is interned by the parser, so it costs no extra
# bytes per use.
_DATA_PREFIX = "data#"

# Bazel keeps one empty depset per order, process-wide.
_NO_ENTRIES = depset()

_ENTRY_FIELDS = ["name", "runfiles", "kind", "rank", "do_not_merge", "weight", "merge_affinity"]

# ---------------------------------------------------------------- producer side

def _entry(*, name, runfiles, kind = "", rank = _RANK_EXECUTABLE, do_not_merge = False, weight = None, merge_affinity = ""):
    """Creates one validated group entry.

    Args:
        name: Group name (non-empty string). Prefix it with something unique to
            your ruleset, e.g. "my_rules#interpreter"; names live in a namespace
            shared by every provider merged into the same binary.
        runfiles: A runfiles object holding this group's contents.
        kind: One of lib.KINDS. A stable selector for packagers, unaffected by
            renaming. Does not influence ordering or merging. Default "".
        rank: Partial ordering key. Lower rank = earlier layer. Default 0.
        do_not_merge: If True, packagers must not merge this group. Default False.
        weight: Merge priority hint (int >= 0 or None). Lighter groups merge
            first. Default None.
        merge_affinity: Merge grouping hint. Groups that share an affinity are
            preferred merge partners. "" means no affinity. Default "".

    Returns:
        A group entry, suitable as an element of a RunfilesGroupInfo entry depset.
    """

    # Validation happens here, once per group, because the depset element type is
    # only weakly checked: every struct-like value has element type "struct", so a
    # malformed foreign entry would type-check and then fail inside somebody
    # else's consumer.
    if type(name) != "string" or not name:
        fail("lib.entry: name must be a non-empty string, got ", repr(name))
    if type(runfiles) != "runfiles":
        fail("lib.entry: runfiles must be a runfiles object, got ", type(runfiles))
    if kind not in KINDS:
        fail("lib.entry: kind must be one of {}, got {}".format(KINDS, repr(kind)))
    if type(rank) != "int":
        fail("lib.entry: rank must be an int, got ", type(rank))
    if type(do_not_merge) != "bool":
        fail("lib.entry: do_not_merge must be a bool, got ", type(do_not_merge))
    if weight != None:
        if type(weight) != "int":
            fail("lib.entry: weight must be an int or None, got ", type(weight))
        if weight < 0:
            fail("lib.entry: weight must be >= 0, got ", weight)
    if type(merge_affinity) != "string":
        fail("lib.entry: merge_affinity must be a string, got ", type(merge_affinity))
    return RunfilesGroupEntryInfo(
        name = name,
        runfiles = runfiles,
        kind = kind,
        rank = rank,
        do_not_merge = do_not_merge,
        weight = weight,
        merge_affinity = merge_affinity,
    )

def _derive(entry, **overrides):
    """Copies an entry, changing only the fields passed.

    Args:
        entry: The entry to copy.
        **overrides: Any subset of the fields lib.entry() takes.

    Returns:
        A new validated entry.
    """
    for field in overrides:
        if field not in _ENTRY_FIELDS:
            fail("lib.derive: unknown field '{}', expected one of {}".format(field, _ENTRY_FIELDS))
    return _entry(
        name = overrides.get("name", entry.name),
        runfiles = overrides.get("runfiles", entry.runfiles),
        kind = overrides.get("kind", entry.kind),
        rank = overrides.get("rank", entry.rank),
        do_not_merge = overrides.get("do_not_merge", entry.do_not_merge),
        weight = overrides.get("weight", entry.weight),
        merge_affinity = overrides.get("merge_affinity", entry.merge_affinity),
    )

def _entries(direct = [], transitive = []):
    """Builds an entry depset with the order the protocol requires.

    Args:
        direct: Entries owned by this target.
        transitive: Entry depsets from dependencies, e.g. lib.collect()'s result.

    Returns:
        A depset of entries, order "default".
    """

    # "default" (stable) order is the only one that can be merged with any other,
    # which a producer needs in order to combine entry depsets from foreign
    # rulesets. Traversal order is never observable: lib.resolve() sorts.
    return depset(direct, transitive = transitive)

def _data_entry(ctx, dep):
    """Synthesizes the entry for a dependency that provides no runfiles groups.

    The name is derived from the dependency's label, so two targets that share a
    data dependency synthesize the same group name and lib.resolve() folds them
    back into one group.

    Args:
        ctx: The rule context.
        dep: A Target without RunfilesGroupInfo.

    Returns:
        A group entry covering the dependency's files and default runfiles.
    """

    # Read DefaultInfo once: on a target that does not return it explicitly every
    # access constructs a fresh delegating instance, and every `.files` read a
    # fresh depset wrapper.
    default_info = dep[DefaultInfo]
    runfiles = default_info.default_runfiles

    # default_runfiles is declared nullable on the Starlark API surface, and
    # RunfilesProvider's factories accept null unchecked. No path through
    # dep[DefaultInfo] appears to produce None today, so this branch costs one
    # comparison and never runs -- keep it rather than depend on that.
    if runfiles == None:
        runfiles = ctx.runfiles()
    files = default_info.files

    # Truth-testing a depset is O(1). Skipping the wrapper for a dependency that
    # contributes no files avoids a runfiles object and a nested set per
    # (target, data dep) edge, retained for the life of the provider.
    #
    # A dep whose DefaultInfo.files is topological- or preorder-ordered fails here:
    # ctx.runfiles(transitive_files = ...) only accepts default and postorder. That
    # is unfixable from Starlark -- a depset's order cannot be read back or changed
    # -- so it is a documented restriction on what may appear in `data`.
    if files:
        runfiles = ctx.runfiles(transitive_files = files).merge(runfiles)
    return _entry(name = _DATA_PREFIX + str(dep.label), runfiles = runfiles)

def _collect(ctx, *, deps, data, own = []):
    """Returns the entry depset for a target: its own entries plus its dependencies'.

    O(number of direct dependencies); never flattens anything.

    `deps` and `data` are mandatory because handling `data` is the protocol's
    classic footgun: pass `data = []` explicitly if your rule has none.

    Pass this target's own entries as `own` rather than wrapping the result in
    another depset. A depset's depth grows by one per nesting level and Bazel
    rejects depsets deeper than --nested_set_depth_limit (3500 by default), so a
    long dependency chain has half as much headroom if every level adds two
    levels instead of one.

    Args:
        ctx: The rule context.
        deps: Targets whose groups this target propagates -- typically the
            ruleset's own *_library targets, which provide RunfilesGroupInfo.
        data: Arbitrary targets. Those without RunfilesGroupInfo get one
            synthesized "data#<canonical label>" entry each.
        own: Entries this target owns, built with lib.entry().

    Returns:
        A depset of entries.
    """
    direct = list(own)
    transitive = []
    for dep_list in (deps, data):
        for dep in dep_list:
            if RunfilesGroupInfo in dep:
                # By reference: depset(transitive = [x]) with nothing new returns
                # x's own depset object, so propagation allocates nothing.
                transitive.append(dep[RunfilesGroupInfo].entries)
            else:
                direct.append(_data_entry(ctx, dep))

    # executable_group lives on RunfilesGroupInfo, not on entries, and is never
    # propagated -- so nothing has to be stripped from a dependency's groups.
    if not direct:
        if not transitive:
            return _NO_ENTRIES
        if len(transitive) == 1:
            return transitive[0]
    return depset(direct, transitive = transitive)


# ---------------------------------------------------------------- consumer side

def _order_key(entry):
    # A module-level def, so sorted(key = _order_key) allocates no function value
    # and no closure cell per call site.
    return (entry.rank, entry.name)

def _make_resolved(by_name, executable_group):
    return struct(
        groups = sorted(by_name.values(), key = _order_key),
        by_name = by_name,
        executable_group = executable_group,
    )

def _check_entry(where, entry):
    for field in _ENTRY_FIELDS:
        if not hasattr(entry, field):
            fail("{}: entry is missing field '{}'; build entries with lib.entry() or lib.derive()".format(where, field))
    if entry.kind not in KINDS:
        fail("{}: entry '{}' has kind {}, expected one of {}".format(where, entry.name, repr(entry.kind), KINDS))

def _resolved(groups, *, executable_group = None):
    """Builds a resolved group set from a list of entries, ordered by (rank, name).

    This is what a RunfilesGroupTransformInfo transform returns.

    Args:
        groups: List of entries. Names must be unique.
        executable_group: Name of the group carrying the executable, or None. It
            must name one of `groups`.

    Returns:
        struct(groups, by_name, executable_group).
    """
    by_name = {}
    for entry in groups:
        _check_entry("lib.resolved", entry)
        if entry.name in by_name:
            fail("lib.resolved: duplicate group name '{}'".format(entry.name))
        by_name[entry.name] = entry
    if executable_group != None and executable_group not in by_name:
        fail("lib.resolved: executable_group '{}' names no group. Present groups: {}".format(
            executable_group,
            sorted(by_name),
        ))
    return _make_resolved(by_name, executable_group)

def _fold(entries):
    """Folds a flat list of entries into a dict of group name -> entry.

    Duplicate names are legal and expected: two targets can each synthesize an
    entry for the same shared data dependency, and runfiles objects have no value
    equality, so a depset cannot collapse them. They are unioned rather than
    resolved last-wins, which would drop one side's files.

    Combination is order-independent, so the result never depends on the depset's
    traversal order:
        runfiles       one merge_all over all parts, not a pairwise fold: a fold
                       would deepen the artifact DAG once per duplicate and can
                       hit the nested set depth limit.
        rank           min
        do_not_merge   or
        weight         max, not sum -- duplicates are the same bytes reached
                       twice, and merging unions rather than concatenates, so
                       summing would inflate the cost model lib.limit() consumes.
        kind           the non-empty one, lexicographic min if both are set
        merge_affinity likewise
    """
    first = {}
    parts = {}
    for entry in entries:
        _check_entry("lib.resolve", entry)
        name = entry.name
        previous = first.get(name)
        if previous == None:
            first[name] = entry
            continue
        if previous == entry:
            # Value equality: identical entries collapse for free.
            continue
        acc = parts.get(name)
        if acc == None:
            acc = [previous.runfiles]
            parts[name] = acc
        acc.append(entry.runfiles)
        if previous.weight == None:
            weight = entry.weight
        elif entry.weight == None:
            weight = previous.weight
        else:
            weight = max(previous.weight, entry.weight)
        first[name] = _derive(
            previous,
            kind = _combine_str(previous.kind, entry.kind),
            rank = min(previous.rank, entry.rank),
            do_not_merge = previous.do_not_merge or entry.do_not_merge,
            weight = weight,
            merge_affinity = _combine_str(previous.merge_affinity, entry.merge_affinity),
        )
    for name, acc in parts.items():
        first[name] = _derive(first[name], runfiles = acc[0].merge_all(acc[1:]))
    return first

def _combine_str(a, b):
    if not a:
        return b
    if not b:
        return a
    return min(a, b)

def _apply_overlay(by_name, executable_group, metadata_info):
    """Applies one RunfilesGroupMetadataInfo. Fields a patch omits stay unchanged."""
    for name, patch in metadata_info.groups.items():
        entry = by_name.get(name)
        if entry == None:
            # Overrides for groups that do not exist are ignored, so one hint can
            # be attached to targets producing different group sets.
            continue
        overrides = {}
        for field in ENTRY_PATCH_FIELDS:
            if hasattr(patch, field):
                overrides[field] = getattr(patch, field)
        if overrides:
            by_name[name] = _derive(entry, **overrides)
        if hasattr(patch, "executable_group"):
            if patch.executable_group:
                executable_group = name
            elif executable_group == name:
                executable_group = None
    return executable_group

def _unpack(source):
    """Returns (entries depset or None, executable_group) for a resolve source."""
    kind = type(source)
    if kind == "depset":
        return (source, None)
    if kind == "Target":
        if RunfilesGroupInfo in source:
            info = source[RunfilesGroupInfo]
            return (info.entries, info.executable_group)
        return (None, None)
    if kind == "struct" and hasattr(source, "entries"):
        return (source.entries, getattr(source, "executable_group", None))
    fail("lib.resolve: expected a Target, a RunfilesGroupInfo or a depset of entries, got ", kind)

def _resolve(source, *, aspect_hints):
    """Flattens, folds, overlays, transforms and orders a target's runfiles groups.

    This is the only place in the protocol that flattens a depset. Call it once per
    *consuming* target, never from a library rule.

    `aspect_hints` is a mandatory keyword: with a default, the correct call and the
    call that silently ignores every user hint look identical. Pass
    `ctx.rule.attr.aspect_hints` from an aspect, or `[]`.

    Args:
        source: A Target, a RunfilesGroupInfo, or a depset of entries.
        aspect_hints: The target's aspect_hints (list of Targets), or [].

    Returns:
        struct(groups, by_name, executable_group), or None when the source carries
        no groups at all -- package DefaultInfo.default_runfiles as a single group
        in that case.
    """
    entries, executable_group = _unpack(source)
    if entries == None:
        return None
    by_name = _fold(entries.to_list())
    if not by_name:
        return None
    if executable_group != None and executable_group not in by_name:
        fail("lib.resolve: executable_group '{}' names no group in the entry depset. Present groups: {}".format(
            executable_group,
            sorted(by_name),
        ))

    # Overrides are accumulated before the transforms run, so a transform sees the
    # overridden metadata. The target's own overrides come first, then the hints in
    # order, per-key last-wins.
    if type(source) == "Target" and RunfilesGroupMetadataInfo in source:
        executable_group = _apply_overlay(by_name, executable_group, source[RunfilesGroupMetadataInfo])
    for hint in aspect_hints:
        if RunfilesGroupMetadataInfo in hint:
            executable_group = _apply_overlay(by_name, executable_group, hint[RunfilesGroupMetadataInfo])

    resolved = _make_resolved(by_name, executable_group)

    for hint in aspect_hints:
        if RunfilesGroupTransformInfo in hint:
            result = hint[RunfilesGroupTransformInfo].transform(resolved)
            if type(result) != "struct" or not hasattr(result, "groups"):
                fail("aspect_hint {}: transform must return lib.resolved(...), got {}".format(hint.label, type(result)))

            # Re-validated here so that a transform which drops the executable
            # group or emits a hand-rolled entry fails naming the hint, rather
            # than three rules downstream.
            resolved = _resolved(
                result.groups,
                executable_group = getattr(result, "executable_group", None),
            )
    return resolved

def _group_names(resolved):
    """Returns the sorted group names of a resolved group set."""
    return sorted(resolved.by_name)

# -------------------------------------------------------------- merge to limit

def _effective_weight(entry, default_weight):
    return entry.weight if entry.weight != None else default_weight

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

def _cheapest_pair(buckets, by_name, default_weight):
    """Returns the cheapest mergeable pair as (lighter, heavier), or None.

    Cost is the combined effective weight of the two lightest groups in a bucket.
    Ties break deterministically on (cost, rank, lighter, heavier).

    The two lightest are found with a linear two-minimum scan rather than by
    sorting: this runs once per merge step, and sorting allocated a decorator, a
    key tuple and a Starlark frame per element per bucket per step.
    """
    best = None
    for _key, names in buckets.items():
        if len(names) < 2:
            continue
        w1 = None
        n1 = None
        w2 = None
        n2 = None
        for name in names:
            entry = by_name.get(name)
            if entry == None:
                continue  # merged away in an earlier step
            weight = _effective_weight(entry, default_weight)
            if n1 == None or weight < w1 or (weight == w1 and name < n1):
                w2 = w1
                n2 = n1
                w1 = weight
                n1 = name
            elif n2 == None or weight < w2 or (weight == w2 and name < n2):
                w2 = weight
                n2 = name
        if n2 == None:
            continue
        candidate = (w1 + w2, by_name[n1].rank, n1, n2)
        if best == None or candidate < best:
            best = candidate
    if best == None:
        return None
    return (best[2], best[3])

def _limit(resolved, *, max_groups, default_weight = 0, merged_group_name = None):
    """Merges groups until at most max_groups remain.

    Merges are picked in this order: same rank only; then prefer pairs that share
    a merge_affinity ("" is the shared "no affinity" bucket); then the two
    lightest by weight.

    Args:
        resolved: A resolved group set, from lib.resolve().
        max_groups: Maximum number of groups to leave.
        default_weight: Weight to assume for entries whose weight is None.
        merged_group_name: Optional function
            (lighter_name, lighter_weight, heavier_name, heavier_weight) -> str
            naming the merged group. If None, the heavier group's name is kept.

    Returns:
        struct(groups, by_name, executable_group, group_count). The caller MUST
        check group_count: do_not_merge and rank constraints can make max_groups
        unreachable.
    """
    if type(default_weight) != "int" or default_weight < 0:
        fail("lib.limit: default_weight must be an int >= 0, got ", repr(default_weight))
    if len(resolved.by_name) <= max_groups:
        return struct(
            groups = resolved.groups,
            by_name = resolved.by_name,
            executable_group = resolved.executable_group,
            group_count = len(resolved.by_name),
        )

    by_name = dict(resolved.by_name)
    executable_group = resolved.executable_group

    # Runfiles of a merged group are accumulated and merged with a single
    # merge_all() at the end. A pairwise fold would retain one two-slot array per
    # step and deepen the artifact DAG once per merge.
    parts = {}

    # Buckets are built once and patched incrementally: a merge only touches the
    # two groups involved and their replacement.
    by_rank_affinity = {}
    by_rank = {}
    for name, entry in by_name.items():
        if entry.do_not_merge:
            continue
        _bucket_add(by_rank_affinity, _affinity_key(entry), name)
        _bucket_add(by_rank, entry.rank, name)

    for _ in range(len(by_name)):
        if len(by_name) <= max_groups:
            break

        # Tier 1: prefer pairs sharing a (rank, merge_affinity).
        # Tier 2: fall back to the cheapest same-rank pair across affinities.
        pair = _cheapest_pair(by_rank_affinity, by_name, default_weight)
        if pair == None:
            pair = _cheapest_pair(by_rank, by_name, default_weight)
        if pair == None:
            break

        lighter, heavier = pair
        light = by_name.pop(lighter)
        heavy = by_name.pop(heavier)
        _bucket_remove(by_rank_affinity, _affinity_key(light), lighter)
        _bucket_remove(by_rank_affinity, _affinity_key(heavy), heavier)
        _bucket_remove(by_rank, light.rank, lighter)
        _bucket_remove(by_rank, heavy.rank, heavier)

        light_weight = _effective_weight(light, default_weight)
        heavy_weight = _effective_weight(heavy, default_weight)
        if merged_group_name != None:
            out_name = merged_group_name(lighter, light_weight, heavier, heavy_weight)
            if type(out_name) != "string" or not out_name:
                fail("lib.limit: merged_group_name must return a non-empty string, got ", repr(out_name))

            # Silently overwriting a third, untouched group would drop its
            # runfiles and violate its do_not_merge.
            if out_name in by_name:
                fail("lib.limit: merged_group_name('{}', '{}') returned '{}', which is an existing group".format(
                    lighter,
                    heavier,
                    out_name,
                ))
        else:
            out_name = heavier

        acc = parts.pop(heavier, None)
        if acc == None:
            acc = [heavy.runfiles]
        light_parts = parts.pop(lighter, None)
        if light_parts == None:
            acc.append(light.runfiles)
        else:
            acc.extend(light_parts)
        parts[out_name] = acc

        merged = _derive(
            heavy,
            name = out_name,
            do_not_merge = False,
            weight = light_weight + heavy_weight,
        )
        by_name[out_name] = merged
        _bucket_add(by_rank_affinity, _affinity_key(merged), out_name)
        _bucket_add(by_rank, merged.rank, out_name)
        if executable_group == lighter or executable_group == heavier:
            executable_group = out_name

    for name, acc in parts.items():
        by_name[name] = _derive(by_name[name], runfiles = acc[0] if len(acc) == 1 else acc[0].merge_all(acc[1:]))

    return struct(
        groups = sorted(by_name.values(), key = _order_key),
        by_name = by_name,
        executable_group = executable_group,
        group_count = len(by_name),
    )

# ------------------------------------------------------------------- metadata

def _merge_metadata(*metadata_infos):
    """Dict-merges RunfilesGroupMetadataInfo overrides. Per-key last-wins.

    Allocates one dict and one provider regardless of arity, and returns a sole
    non-None argument by identity.

    Args:
        *metadata_infos: RunfilesGroupMetadataInfo instances, or None.

    Returns:
        A RunfilesGroupMetadataInfo, or None if every argument was None.
    """
    first = None
    merged = None
    for m in metadata_infos:
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

# ---------------------------------------------------------------- global flag

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

    Args:
        ctx: The rule context.

    Returns:
        True if producing rules should emit RunfilesGroupInfo.
    """
    return ctx.attr._runfiles_group_enabled[BuildSettingInfo].value

lib = struct(
    # producer
    entry = _entry,
    derive = _derive,
    entries = _entries,
    collect = _collect,
    data_entry = _data_entry,
    # consumer
    resolve = _resolve,
    resolved = _resolved,
    group_names = _group_names,
    limit = _limit,
    # metadata overrides (aspect_hints)
    group_metadata = group_metadata,
    merge_metadata = _merge_metadata,
    KINDS = KINDS,
    DEFAULT_METADATA = DEFAULT_METADATA,
    # Global on/off switch (see //runfiles_group:enabled). RULE_ATTRS and
    # is_enabled are a pair — see their docs above.
    RULE_ATTRS = RULE_ATTRS,
    is_enabled = _is_enabled,
    # Recommended rank anchors (see README "Recommended rank values").
    RANK_FOUNDATION = _RANK_FOUNDATION,
    RANK_SHARED_DEPS = _RANK_SHARED_DEPS,
    RANK_EXECUTABLE = _RANK_EXECUTABLE,
)
