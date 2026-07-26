"""Library for producing and consuming runfiles groups.

GROUP NAMES come in two forms, because there are two kinds of group:

    a Label   -- a PER-TARGET group: "the runfiles this one target contributes".
                 Pass ctx.label for your own group, or dep.label for a dependency's.
                 Globally unique, so it needs no ruleset prefix, and free: Bazel
                 already interns the Label.
    a string  -- a NAMED group that several targets contribute to: "interpreter",
                 "std", "third_party". Strings share one namespace across every
                 provider merged into a binary, so prefix them with something
                 unique to your ruleset ("my_rules#interpreter").

Both forms are ordered, folded, merged and looked up the same way. Use
lib.name_str() wherever you need a plain string -- an artifact name, an output
group key, a manifest line, an error message.

PRODUCER SIDE -- O(1) allocations per target, never flattens anything:

    lib.entry(name, content, kind, rank, do_not_merge, weight, merge_affinity)
        One group entry. The only supported entry constructor. `content` is either a
        runfiles object or, for a group that is only files, the depset of File
        itself -- which costs nothing, where wrapping it in a runfiles object
        retains one per group for no added information.
    lib.derive(entry, **overrides)
        A copy of an entry with some fields changed. Use this instead of
        re-listing every field, which is how a re-ranking producer or a renaming
        transform silently resets the fields it forgot.
    lib.collect(ctx, deps = , data = , own = )
        The whole entry depset for a target: its own entries plus its
        dependencies'. Dependencies that provide RunfilesGroupInfo contribute
        their `entries` by reference; the others get one synthesized per-target
        entry each, named by their Label.
    lib.entries(direct = , transitive = )
        An entry depset with the order the protocol requires, for producers that
        do not collect from dependencies.

    Then: RunfilesGroupInfo(entries = ..., executable_group = ...)

CONSUMER SIDE -- flatten exactly ONCE per consuming target:

    lib.resolve(ctx, source, aspect_hints = )
        THE ONLY to_list() IN THE PROTOCOL. Flattens the entry depset, folds
        duplicate group names, applies the metadata overrides from the target and
        from `aspect_hints`, runs the hint transforms, and orders by (rank, name).
        Returns struct(groups, by_name, executable_group), or None when the source
        carries no groups -- in which case the packager must fall back to
        DefaultInfo.default_runfiles as a single group.
          groups:           list of entries ordered by (rank, name)
          by_name:          dict[Label|str, entry]
          executable_group: Label, str or None, guaranteed to be a key of by_name
    lib.resolved(groups, executable_group = )
        Builds a resolved value from a list of entries. This is what a transform
        returns.
    lib.files(entry)
        Every File a group contributes, as a depset. Both content forms.
    lib.runfiles(ctx, entry)
        A group's contents as a runfiles object. Both content forms; allocates
        only for the depset form, so never hold the result in a provider.
    lib.union(ctx, contents)
        Several groups' contents unioned into one, for a producer that aggregates
        groups. Stays in the depset form when every part is one.
    lib.name_str(entry_or_name)
        The canonical string form of a group name. Accepts an entry too.
    lib.group_names(resolved)
        Sorted list of canonical name strings.
    lib.index_by_name_str(resolved)
        dict[str, entry], for configuration that names groups as strings.
    lib.limit(ctx, resolved, max_groups = , default_weight = , merged_group_name = )
        Merges groups until at most max_groups remain, respecting rank,
        do_not_merge, merge_affinity and weight. Returns a resolved value plus
        `group_count`, which the caller MUST check: do_not_merge and rank
        constraints can make max_groups unreachable.
    lib.merge_metadata(*metadata_infos)
        Dict-merges RunfilesGroupMetadataInfo overrides. Per-key last-wins.
    lib.group_metadata(**fields)
        A metadata override patch carrying only the fields passed.

lib.resolve and lib.limit take a `ctx` for one reason: unioning a files-only
group's depset with another group's runfiles object requires ctx.runfiles(), the
only lift Bazel offers. They allocate nothing when no union mixes the two forms.

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

# Bazel keeps one empty depset per order, process-wide.
_NO_ENTRIES = depset()

_DEPSET_TYPE = type(_NO_ENTRIES)
_LABEL_TYPE = type(Label("@rules_runfiles_group//runfiles_group"))
_STRING_TYPE = type("")
_INT_TYPE = type(0)
_BOOL_TYPE = type(False)
_TARGET_TYPE = "Target"
_STRUCT_TYPE = type(struct())

_ENTRY_FIELDS = ["name", "content", "kind", "rank", "do_not_merge", "weight", "merge_affinity"]

# ------------------------------------------------------------------ group names

def _name_str(value):
    """Canonical string form of a group name, for display and artifact naming.

    Not injective by construction: nothing stops a producer from naming one group
    with `Label("//p:t")` and another with the string `"@@//p:t"`. Anything that
    *keys* on the result must therefore reject a collision rather than let one
    group quietly overwrite another -- see lib.index_by_name_str and lib.limit.

    Args:
        value: A group name (a Label or a string), or an entry.

    Returns:
        str(label) for a per-target group, the name itself for a named one.
    """

    # Label is checked before the entry case on purpose: a Label has a `name`
    # field of its own (the target name), so probing for `.name` first would
    # quietly return "lib_a" instead of "//src:lib_a".
    if type(value) == _LABEL_TYPE:
        return str(value)
    if type(value) == _STRING_TYPE:
        return value
    name = value.name
    if type(name) == _LABEL_TYPE:
        return str(name)
    return name

def _check_name(where, name):
    kind = type(name)
    if kind == _LABEL_TYPE:
        return
    if kind != _STRING_TYPE or not name:
        fail("{}: name must be a Label or a non-empty string, got {}".format(where, repr(name)))

def _sort_key(name):
    """A comparison token for a group name that works across both forms.

    A tuple comparison stops at the first unequal element, so putting the form
    discriminator first means a Label is never compared against a string -- which
    Starlark rejects outright. Per-target groups sort before named ones within a
    rank; intra-rank order is unspecified by the protocol either way.
    """
    if type(name) == _LABEL_TYPE:
        return (0, name)
    return (1, name)

def _sorted_name_strs(names):
    """Sorted string forms of a collection of group names, for diagnostics."""
    return sorted([_name_str(name) for name in names])

def _described_name(name):
    """A group name rendered with its form, so a Label and a string never look alike."""
    if type(name) == _LABEL_TYPE:
        return "Label({})".format(repr(_name_str(name)))
    return repr(name)

# --------------------------------------------------------------- entry contents

def _check_content(where, content):
    """Fails unless content is one of the two legal forms. Allocates nothing."""
    if type(content) == _DEPSET_TYPE:
        return

    # A capability test rather than a type name, and merge_all is the right
    # capability: it is what _union() and every merging packager calls, and no other
    # value a producer might pass by mistake has it -- a depset's whole Starlark
    # surface is to_list(). A struct forging the field still gets through; that is
    # the residual cost of not naming the type, and it fails on first use.
    if not hasattr(content, "merge_all"):
        fail("{}: content must be a runfiles object or a depset of File, got {}".format(
            where,
            type(content),
        ))

def _stored_content(where, content):
    """Validates content and returns the form an entry stores."""
    _check_content(where, content)
    if type(content) != _DEPSET_TYPE:
        return content

    # Rewrapped in default order rather than stored as handed over:
    # ctx.runfiles(transitive_files = ) rejects preorder and topological depsets --
    # unconditionally, empty ones included -- and Starlark can neither read a
    # depset's order back nor probe it soundly. Laundering here is the only way a
    # producer's depset cannot fail inside somebody else's packaging rule, and it is
    # free for the case that matters: depset(transitive = [d]) hands back d itself
    # when d is already default-ordered.
    return depset(transitive = [content])

def _files(entry):
    """Returns every File a group contributes, as a depset.

    The read path for a packager that only needs paths -- a manifest, an output
    group, a layer's contents. It allocates nothing for a files-only group and, for
    a runfiles-form group, only the depset wrapper Bazel builds per `.files` access.

    Note what it deliberately does not include: the symlinks, root symlinks and
    empty filenames of a runfiles-form group. A packager that must place a complete
    runfiles tree wants lib.runfiles() instead.

    Args:
        entry: A group entry.

    Returns:
        A depset of File.
    """
    content = entry.content
    if type(content) == _DEPSET_TYPE:
        return content
    return content.files

def _runfiles(ctx, entry):
    """Returns a group's contents as a runfiles object.

    Identity for a group that already carries one; for a files-only group it builds
    one, which is why this takes a ctx. Never store the result in a provider: doing
    so re-retains, per consuming target, exactly the object the producer avoided.

    Args:
        ctx: The rule or aspect context. ctx.runfiles() is available in both.
        entry: A group entry.

    Returns:
        A runfiles object holding the group's contents.
    """
    content = entry.content
    if type(content) == _DEPSET_TYPE:
        return ctx.runfiles(transitive_files = content)
    return content

def _union(ctx, contents):
    """Unions several groups' contents into one content value.

    For a producer that aggregates groups -- one group per repository out of one
    group per target, say. Pass `entry.content` values and/or runfiles objects of
    your own; the result goes straight into lib.entry(content = ...).

    Stays in the depset form when every part is one, so aggregating files-only
    groups still retains no runfiles object. A mixed union is the only thing in the
    protocol that must build one, because Bazel offers no way to merge a depset into
    a runfiles object other than ctx.runfiles().

    Args:
        ctx: The rule or aspect context.
        contents: List of content values (runfiles objects or depsets of File).

    Returns:
        A content value: a depset of File if every part was one, else a runfiles
        object.
    """
    files = []
    runfiles = []
    for content in contents:
        if type(content) == _DEPSET_TYPE:
            files.append(content)
        else:
            _check_content("lib.union", content)
            runfiles.append(content)
    if not runfiles:
        # Returns the sole part itself when there is only one.
        return depset(transitive = files)
    if files:
        runfiles.append(ctx.runfiles(transitive_files = depset(transitive = files)))
    if len(runfiles) == 1:
        return runfiles[0]

    # One merge_all over all parts, not a pairwise fold: a fold retains a two-slot
    # array per step and deepens the artifact DAG once per part.
    return runfiles[0].merge_all(runfiles[1:])

# ---------------------------------------------------------------- producer side

def _entry(*, name, content, kind = "", rank = _RANK_EXECUTABLE, do_not_merge = False, weight = None, merge_affinity = ""):
    """Creates one validated group entry.

    Args:
        name: The group's identity, in one of two forms.

            A **Label** for a per-target group -- "the runfiles this one target
            contributes". Pass `ctx.label` for your own, or a dependency's
            `dep.label`. A Label is globally unique, so it needs no ruleset prefix,
            and it costs nothing: Bazel already interns it.

            A **string** for a named group that several targets contribute to --
            "interpreter", "std", "third_party". Strings live in a namespace shared
            by every provider merged into the same binary, so prefix them with
            something unique to your ruleset, e.g. "my_rules#interpreter".
        content: The group's contents, in one of two forms.

            A **depset of File** for a group that is only files, which most
            *_library groups are. Hand over the depset you already built: the entry
            then points at it, where wrapping it in a runfiles object would retain
            an extra ~64 bytes per group -- a 7-field Runfiles plus the nested set
            node its compile-order builder has to allocate -- carrying no
            information the depset does not.

            A **runfiles object** for anything else, and for contents you received
            from another rule. This is the general form: it is the only one that can
            carry symlinks, root symlinks and empty filenames.

            Consumers read either form through lib.files() and lib.runfiles().
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
    _check_name("lib.entry", name)

    content = _stored_content("lib.entry", content)
    if kind not in KINDS:
        fail("lib.entry: kind must be one of {}, got {}".format(KINDS, repr(kind)))
    if type(rank) != _INT_TYPE:
        fail("lib.entry: rank must be an int, got ", type(rank))
    if type(do_not_merge) != _BOOL_TYPE:
        fail("lib.entry: do_not_merge must be a bool, got ", type(do_not_merge))
    if weight != None:
        if type(weight) != _INT_TYPE:
            fail("lib.entry: weight must be an int or None, got ", type(weight))
        if weight < 0:
            fail("lib.entry: weight must be >= 0, got ", weight)
    if type(merge_affinity) != _STRING_TYPE:
        fail("lib.entry: merge_affinity must be a string, got ", type(merge_affinity))
    return RunfilesGroupEntryInfo(
        name = name,
        content = content,
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
        content = overrides.get("content", entry.content),
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

    It is a per-target group named by the dependency's Label, so two targets that
    share a data dependency synthesize the same group and lib.resolve() folds them
    back into one. Naming it with the Label rather than a string derived from it
    means this costs nothing: Bazel already interns the Label and the dependency
    already holds it.

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
    # The dependency's depset is laundered through depset(transitive = ) before it
    # reaches ctx.runfiles(transitive_files = ), which accepts only default and
    # postorder. Starlark cannot read an order back to check for a bad one, but it
    # can neutralize it: the rewrap yields a default-ordered depset, and hands back
    # the original object when it already was one. Without it, a dependency
    # publishing DefaultInfo(files = depset(..., order = "topological")) could not
    # appear in `data` at all.
    #
    # This synthesized entry keeps the runfiles form: deciding to hand over `files`
    # alone would mean inspecting a foreign runfiles object to see whether it holds
    # anything besides files, and reading its empty_filenames is O(all files) for a
    # dependency that carries a real empty-files supplier.
    if files:
        runfiles = ctx.runfiles(transitive_files = depset(transitive = [files])).merge(runfiles)
    return _entry(name = dep.label, content = runfiles)

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
            synthesized per-target entry each, named by their Label.
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
    # and no closure cell per call site. The name is wrapped in its form
    # discriminator so a Label and a string are never compared against each other.
    name = entry.name
    if type(name) == _LABEL_TYPE:
        return (entry.rank, 0, name)
    return (entry.rank, 1, name)

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
    _check_name(where, entry.name)

    # Checked here as well as in lib.entry(), because an entry can reach a consumer
    # without having been built by lib: a depset's element type is only weakly
    # checked, so a foreign hand-rolled entry type-checks and would then fail inside
    # a union or a packager's read. Inlined rather than routed through
    # _check_content so that the happy path -- once per entry per resolve -- formats
    # nothing.
    content = entry.content
    if type(content) != _DEPSET_TYPE and not hasattr(content, "merge_all"):
        fail("{}: entry '{}' content must be a runfiles object or a depset of File, got {}".format(
            where,
            _name_str(entry.name),
            type(content),
        ))
    if entry.kind not in KINDS:
        fail("{}: entry '{}' has kind {}, expected one of {}".format(where, _name_str(entry.name), repr(entry.kind), KINDS))

def _resolved(groups, *, executable_group = None):
    """Builds a resolved group set from a list of entries, ordered by (rank, name).

    This is what a RunfilesGroupTransformInfo transform returns.

    Args:
        groups: List of entries. Names must be unique.
        executable_group: The name (Label or string) of the group carrying the
            executable, or None. It must name one of `groups`.

    Returns:
        struct(groups, by_name, executable_group).
    """
    by_name = {}
    for entry in groups:
        _check_entry("lib.resolved", entry)
        if entry.name in by_name:
            fail("lib.resolved: duplicate group name '{}'".format(_name_str(entry.name)))
        by_name[entry.name] = entry
    if executable_group != None:
        _check_name("lib.resolved: executable_group", executable_group)
        if executable_group not in by_name:
            fail("lib.resolved: executable_group {} names no group. Present groups: {}".format(
                _described_name(executable_group),
                _sorted_name_strs(by_name),
            ))
    return _make_resolved(by_name, executable_group)

def _fold(ctx, entries):
    """Folds a flat list of entries into a dict of group name -> entry.

    Duplicate names are legal and expected: two targets can each synthesize an
    entry for the same shared data dependency, and runfiles objects have no value
    equality, so a depset cannot collapse them. They are unioned rather than
    resolved last-wins, which would drop one side's files.

    Combination is order-independent, so the result never depends on the depset's
    traversal order:
        content        one lib.union() over all parts -- which stays in the depset
                       form unless the parts mix forms, and never folds pairwise:
                       a fold would deepen the artifact DAG once per duplicate and
                       can hit the nested set depth limit.
        rank           min
        do_not_merge   or
        weight         max, not sum -- duplicates are the same bytes reached
                       twice, and merging unions rather than concatenates, so
                       summing would inflate the cost model lib.limit() consumes.
        kind           the non-empty one, lexicographic min if both are set
        merge_affinity likewise

    A group with no duplicates is handed through untouched, in whichever content
    form its producer chose. Nothing is materialized on its behalf.
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
            acc = [previous.content]
            parts[name] = acc
        acc.append(entry.content)
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
        first[name] = _derive(first[name], content = _union(ctx, acc))
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
    if kind == _DEPSET_TYPE:
        return (source, None)
    if kind == _TARGET_TYPE:
        if RunfilesGroupInfo in source:
            info = source[RunfilesGroupInfo]
            return (info.entries, info.executable_group)
        return (None, None)
    if kind == "struct" and hasattr(source, "entries"):
        return (source.entries, getattr(source, "executable_group", None))
    fail("lib.resolve: expected a Target, a RunfilesGroupInfo or a depset of entries, got ", kind)

def _check_ctx(where, ctx):
    # A cheap guard with an expensive payoff: `where(source, aspect_hints = h)` --
    # the pre-ctx spelling of this call -- otherwise fails with "missing 1 required
    # positional argument: source", which points a migrating caller at the wrong
    # parameter. Nothing but a ctx carries a `runfiles` member.
    if not hasattr(ctx, "runfiles"):
        fail("{}: first argument must be the rule or aspect ctx, got {}".format(where, type(ctx)))

def _resolve(ctx, source, *, aspect_hints):
    """Flattens, folds, overlays, transforms and orders a target's runfiles groups.

    This is the only place in the protocol that flattens a depset. Call it once per
    *consuming* target, never from a library rule.

    `aspect_hints` is a mandatory keyword: with a default, the correct call and the
    call that silently ignores every user hint look identical. Pass
    `ctx.rule.attr.aspect_hints` from an aspect, or `[]`.

    Args:
        ctx: The rule or aspect context. Used only if folding duplicate group names
            has to union a files-only group's depset with another group's runfiles
            object, which needs ctx.runfiles() -- the only lift Bazel offers.
        source: A Target, a RunfilesGroupInfo, or a depset of entries.
        aspect_hints: The target's aspect_hints (list of Targets), or [].

    Returns:
        struct(groups, by_name, executable_group), or None when the source carries
        no groups at all -- package DefaultInfo.default_runfiles as a single group
        in that case.
    """
    _check_ctx("lib.resolve", ctx)
    entries, executable_group = _unpack(source)
    if entries == None:
        return None
    by_name = _fold(ctx, entries.to_list())
    if not by_name:
        return None
    if executable_group != None and executable_group not in by_name:
        fail("lib.resolve: executable_group {} names no group in the entry depset. Present groups: {}".format(
            _described_name(executable_group),
            _sorted_name_strs(by_name),
        ))

    # Overrides are accumulated before the transforms run, so a transform sees the
    # overridden metadata. The target's own overrides come first, then the hints in
    # order, per-key last-wins.
    if type(source) == _TARGET_TYPE and RunfilesGroupMetadataInfo in source:
        executable_group = _apply_overlay(by_name, executable_group, source[RunfilesGroupMetadataInfo])
    for hint in aspect_hints:
        if RunfilesGroupMetadataInfo in hint:
            executable_group = _apply_overlay(by_name, executable_group, hint[RunfilesGroupMetadataInfo])

    resolved = _make_resolved(by_name, executable_group)

    for hint in aspect_hints:
        if RunfilesGroupTransformInfo in hint:
            result = hint[RunfilesGroupTransformInfo].transform(resolved)
            if type(result) != _STRUCT_TYPE or not hasattr(result, "groups"):
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
    """Returns the group names of a resolved group set, as sorted strings.

    Args:
        resolved: A resolved group set, from lib.resolve().

    Returns:
        A sorted list of canonical name strings. Use resolved.by_name if you need
        the names in their original Label-or-string form.
    """
    return _sorted_name_strs(resolved.by_name)

def _index_by_name_str(resolved):
    """Indexes a resolved group set by canonical name string.

    Useful for a packager whose user-facing configuration names groups as strings:
    a user writes "@@//src:lib_a" (the canonical form of a per-target group's Label)
    or "my_rules#interpreter", and this resolves either against the actual entries.

    Args:
        resolved: A resolved group set, from lib.resolve().

    Returns:
        dict[str, entry].
    """
    by_str = {}
    for name, entry in resolved.by_name.items():
        as_str = _name_str(name)

        # A Label and the string form of that same label are two distinct groups
        # that render identically. Returning a dict quietly missing one of them is
        # how a packager loses a group's files.
        if as_str in by_str:
            fail(("lib.index_by_name_str: groups {} and {} both render as '{}'. Name one of " +
                  "them differently -- a string that spells out a Label's canonical form is a " +
                  "different group from the Label itself.").format(
                _described_name(by_str[as_str].name),
                _described_name(name),
                as_str,
            ))
        by_str[as_str] = entry
    return by_str

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

def _cheapest_pair(buckets, by_name, sort_keys, default_weight):
    """Returns the cheapest mergeable pair as (lighter, heavier), or None.

    Cost is the combined effective weight of the two lightest groups in a bucket.
    Ties break deterministically on (cost, rank, lighter, heavier).

    The two lightest are found with a linear two-minimum scan rather than by
    sorting: this runs once per merge step, and sorting allocated a decorator, a
    key tuple and a Starlark frame per element per bucket per step.

    Names are compared through `sort_keys`, which holds one form-discriminated
    token per group, built once by the caller. Comparing the names directly would
    fail as soon as a per-target (Label) group and a named (string) group land in
    the same bucket.
    """
    best = None
    for _key, names in buckets.items():
        if len(names) < 2:
            continue
        w1 = None
        n1 = None
        k1 = None
        w2 = None
        n2 = None
        k2 = None
        for name in names:
            entry = by_name.get(name)
            if entry == None:
                continue  # merged away in an earlier step
            weight = _effective_weight(entry, default_weight)
            key = sort_keys[name]
            if n1 == None or weight < w1 or (weight == w1 and key < k1):
                w2 = w1
                n2 = n1
                k2 = k1
                w1 = weight
                n1 = name
                k1 = key
            elif n2 == None or weight < w2 or (weight == w2 and key < k2):
                w2 = weight
                n2 = name
                k2 = key
        if n2 == None:
            continue
        candidate = (w1 + w2, by_name[n1].rank, k1, k2)
        if best == None or candidate < best[0]:
            best = (candidate, n1, n2)
    if best == None:
        return None
    return (best[1], best[2])

def _limit(ctx, resolved, *, max_groups, default_weight = 0, merged_group_name = None):
    """Merges groups until at most max_groups remain.

    Merges are picked in this order: same rank only; then prefer pairs that share
    a merge_affinity ("" is the shared "no affinity" bucket); then the two
    lightest by weight.

    Args:
        ctx: The rule or aspect context. Used only where a merged pair mixes a
            files-only group's depset with another group's runfiles object, which
            needs ctx.runfiles().
        resolved: A resolved group set, from lib.resolve().
        max_groups: Maximum number of groups to leave.
        default_weight: Weight to assume for entries whose weight is None.
        merged_group_name: Optional function
            (lighter_name, lighter_weight, heavier_name, heavier_weight) -> name
            naming the merged group. The names it receives are in their original
            Label-or-string form; use lib.name_str() to render them. It may return
            either form, though a merged group is rarely still one target's, so a
            string is the usual answer. If None, the heavier group's name is kept.

    Returns:
        struct(groups, by_name, executable_group, group_count). The caller MUST
        check group_count: do_not_merge and rank constraints can make max_groups
        unreachable.
    """
    _check_ctx("lib.limit", ctx)
    if type(default_weight) != _INT_TYPE or default_weight < 0:
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

    # Canonical forms of the surviving names, so that a merged_group_name callback
    # returning the string spelling of a Label-named group is caught. The raw
    # `out_name in by_name` test below cannot see that: the two are different keys
    # that render identically, and overwriting would drop a group's runfiles.
    name_strs = {}
    if merged_group_name != None:
        for name in by_name:
            name_strs[_name_str(name)] = name

    # Contents of a merged group are accumulated and unioned once at the end. A
    # pairwise fold would retain a two-slot array per step and deepen the artifact
    # DAG once per merge; accumulating also lets a run of files-only groups merge
    # without ever building a runfiles object.
    parts = {}

    # Buckets are built once and patched incrementally: a merge only touches the
    # two groups involved and their replacement. sort_keys holds one comparison
    # token per group so tie-breaking never compares a Label against a string.
    by_rank_affinity = {}
    by_rank = {}
    sort_keys = {}
    for name, entry in by_name.items():
        if entry.do_not_merge:
            # Never bucketed, so never compared: no sort key needed. It cannot
            # become bucketed later either -- the only name added below is
            # out_name, and a collision with an existing group already fails.
            continue
        sort_keys[name] = _sort_key(name)
        _bucket_add(by_rank_affinity, _affinity_key(entry), name)
        _bucket_add(by_rank, entry.rank, name)

    for _ in range(len(by_name)):
        if len(by_name) <= max_groups:
            break

        # Tier 1: prefer pairs sharing a (rank, merge_affinity).
        # Tier 2: fall back to the cheapest same-rank pair across affinities.
        pair = _cheapest_pair(by_rank_affinity, by_name, sort_keys, default_weight)
        if pair == None:
            pair = _cheapest_pair(by_rank, by_name, sort_keys, default_weight)
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
            if type(out_name) != _LABEL_TYPE and (type(out_name) != _STRING_TYPE or not out_name):
                fail("lib.limit: merged_group_name must return a Label or a non-empty string, got ", repr(out_name))

            # Silently overwriting a third, untouched group would drop its
            # runfiles and violate its do_not_merge. Compared in canonical form so
            # that a string spelling of a Label-named group is caught too.
            out_str = _name_str(out_name)
            existing = name_strs.get(out_str)
            if existing != None:
                fail("lib.limit: merged_group_name({}, {}) returned {}, which is an existing group ({})".format(
                    _described_name(lighter),
                    _described_name(heavier),
                    _described_name(out_name),
                    _described_name(existing),
                ))
        else:
            out_name = heavier

        acc = parts.pop(heavier, None)
        if acc == None:
            acc = [heavy.content]
        light_parts = parts.pop(lighter, None)
        if light_parts == None:
            acc.append(light.content)
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
        if merged_group_name != None:
            name_strs.pop(_name_str(lighter), None)
            name_strs.pop(_name_str(heavier), None)
            name_strs[out_str] = out_name
        sort_keys[out_name] = _sort_key(out_name)
        _bucket_add(by_rank_affinity, _affinity_key(merged), out_name)
        _bucket_add(by_rank, merged.rank, out_name)
        if executable_group == lighter or executable_group == heavier:
            executable_group = out_name

    for name, acc in parts.items():
        by_name[name] = _derive(by_name[name], content = _union(ctx, acc))

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
    files = _files,
    runfiles = _runfiles,
    union = _union,
    name_str = _name_str,
    group_names = _group_names,
    index_by_name_str = _index_by_name_str,
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
