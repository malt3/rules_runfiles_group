"""Defines provider for metadata about RunfilesGroupInfo groups.

RunfilesGroupMetadataInfo holds per-group metadata that controls ordering
(rank), merge eligibility (do_not_merge), merge priority (weight), and merge
grouping preference (merge_affinity).
"""

_DOC = """\
Metadata about groups in a RunfilesGroupInfo instance.

Each entry maps a group name to a struct with:
- rank (int): Partial ordering key. Lower rank = earlier. Default 0.
- do_not_merge (bool): If True, packager must not merge this group. Default False.
- weight (int or None): Hint for merge priority. Lighter groups merge first.
  If None, the packager may apply an undefined default. Default None.
- executable_group (bool): If True, signals that the packager should place
  the executable file, runfiles symlinks, repo mapping manifest, and other
  supporting files for the main entrypoint into this group. Default False.
- merge_affinity (str): Best-effort merge grouping hint. When groups must be
  merged to fit a limit, groups that share the same merge_affinity are
  preferred merge partners over groups with a different merge_affinity. It is
  only a preference: merging still falls back across affinities when necessary.
  The empty string "" means "no affinity" — such groups share a common default
  bucket. Default "".

Groups not present in the dict are treated as having default metadata
(rank=0, do_not_merge=False, weight=None, executable_group=False,
merge_affinity="").
"""

_DEFAULT_RANK = 0
_DEFAULT_DO_NOT_MERGE = False
_DEFAULT_WEIGHT = None
_DEFAULT_EXECUTABLE_GROUP = False
_DEFAULT_MERGE_AFFINITY = ""

def _validate(where, rank, do_not_merge, weight, executable_group, merge_affinity):
    if type(rank) != "int":
        fail(where, ": rank must be an int, got ", type(rank))
    if type(do_not_merge) != "bool":
        fail(where, ": do_not_merge must be a bool, got ", type(do_not_merge))
    if weight != None:
        if type(weight) != "int":
            fail(where, ": weight must be an int or None, got ", type(weight))
        if weight < 0:
            fail(where, ": weight must be >= 0, got ", weight)
    if type(executable_group) != "bool":
        fail(where, ": executable_group must be a bool, got ", type(executable_group))
    if type(merge_affinity) != "string":
        fail(where, ": merge_affinity must be a string, got ", type(merge_affinity))

def group_metadata(*, rank = _DEFAULT_RANK, do_not_merge = _DEFAULT_DO_NOT_MERGE, weight = _DEFAULT_WEIGHT, executable_group = _DEFAULT_EXECUTABLE_GROUP, merge_affinity = _DEFAULT_MERGE_AFFINITY):
    """Creates a validated group metadata struct.

    Args:
        rank: Partial ordering key. Lower rank = earlier. Default 0.
        do_not_merge: If True, packager must not merge this group. Default False.
        weight: Merge priority hint (int >= 0 or None). Default None.
        executable_group: If True, the packager should place the executable
            and supporting files into this group. Default False.
        merge_affinity: Best-effort merge grouping hint (str). Groups that share
            the same merge_affinity are preferred merge partners. The empty
            string "" means "no affinity". Default "".

    Returns:
        A struct with rank, do_not_merge, weight, executable_group, and
        merge_affinity fields.
    """
    _validate("group_metadata", rank, do_not_merge, weight, executable_group, merge_affinity)

    # Collapse the all-defaults case onto the module-level singleton. Module
    # globals are frozen after the .bzl is loaded, so every caller shares one
    # 80-byte object instead of allocating its own. Structs compare by value and
    # Starlark has no identity operator, so this is unobservable.
    if (rank == _DEFAULT_RANK and do_not_merge == _DEFAULT_DO_NOT_MERGE and
        weight == _DEFAULT_WEIGHT and executable_group == _DEFAULT_EXECUTABLE_GROUP and
        merge_affinity == _DEFAULT_MERGE_AFFINITY):
        return _DEFAULT_METADATA

    return struct(rank = rank, do_not_merge = do_not_merge, weight = weight, executable_group = executable_group, merge_affinity = merge_affinity)

_DEFAULT_METADATA = struct(
    rank = _DEFAULT_RANK,
    do_not_merge = _DEFAULT_DO_NOT_MERGE,
    weight = _DEFAULT_WEIGHT,
    executable_group = _DEFAULT_EXECUTABLE_GROUP,
    merge_affinity = _DEFAULT_MERGE_AFFINITY,
)

def _normalize_entry(name, entry):
    if type(entry) == "struct":
        if (hasattr(entry, "rank") and hasattr(entry, "do_not_merge") and
            hasattr(entry, "weight") and hasattr(entry, "executable_group") and
            hasattr(entry, "merge_affinity")):
            # Identity fast path: an entry that already carries all five fields
            # is validated in place and handed back as the SAME object.
            #
            # Rebuilding it would allocate a fresh 80-byte struct for every group
            # at every level of the dependency graph, and Bazel cannot undo that:
            # schemaless structs are never interned, and structs nested inside a
            # dict are never visited by unsafeOptimizeMemoryLayout. Propagating
            # the identical object upwards is the only sharing mechanism Starlark
            # offers, and it is what keeps a dep's metadata from being duplicated
            # into every one of its reverse dependencies.
            _validate(
                "RunfilesGroupMetadataInfo entry for group '{}'".format(name),
                entry.rank,
                entry.do_not_merge,
                entry.weight,
                entry.executable_group,
                entry.merge_affinity,
            )
            return entry
        return group_metadata(
            rank = getattr(entry, "rank", _DEFAULT_RANK),
            do_not_merge = getattr(entry, "do_not_merge", _DEFAULT_DO_NOT_MERGE),
            weight = getattr(entry, "weight", _DEFAULT_WEIGHT),
            executable_group = getattr(entry, "executable_group", _DEFAULT_EXECUTABLE_GROUP),
            merge_affinity = getattr(entry, "merge_affinity", _DEFAULT_MERGE_AFFINITY),
        )
    if type(entry) == "dict":
        return group_metadata(
            rank = entry.get("rank", _DEFAULT_RANK),
            do_not_merge = entry.get("do_not_merge", _DEFAULT_DO_NOT_MERGE),
            weight = entry.get("weight", _DEFAULT_WEIGHT),
            executable_group = entry.get("executable_group", _DEFAULT_EXECUTABLE_GROUP),
            merge_affinity = entry.get("merge_affinity", _DEFAULT_MERGE_AFFINITY),
        )
    fail("RunfilesGroupMetadataInfo: entry for group '{}' must be a struct or dict, got {}".format(name, type(entry)))

def _make_runfilesgroupmetadatainfo_init(*, groups):
    if type(groups) != "dict":
        fail("RunfilesGroupMetadataInfo: groups must be a dict, got ", type(groups))
    normalized = {}
    for name, entry in groups.items():
        normalized[name] = _normalize_entry(name, entry)
    return {"groups": normalized}

RunfilesGroupMetadataInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilesgroupmetadatainfo_init,
    fields = {
        "groups": """\
A dict mapping group name (string) to a struct with rank, do_not_merge, weight, executable_group, and merge_affinity fields.
Groups not present get default metadata (rank=0, do_not_merge=False, weight=None, executable_group=False, merge_affinity="").
""",
    },
)

DEFAULT_METADATA = _DEFAULT_METADATA
