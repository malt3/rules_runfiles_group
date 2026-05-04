"""Defines provider for metadata about RunfilesGroupInfo groups.

RunfilesGroupMetadataInfo holds per-group metadata that controls ordering
(rank), merge eligibility (do_not_merge), and merge priority (weight).
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

Groups not present in the dict are treated as having default metadata
(rank=0, do_not_merge=False, weight=None, executable_group=False).
"""

_DEFAULT_RANK = 0
_DEFAULT_DO_NOT_MERGE = False
_DEFAULT_WEIGHT = None
_DEFAULT_EXECUTABLE_GROUP = False

def group_metadata(*, rank = _DEFAULT_RANK, do_not_merge = _DEFAULT_DO_NOT_MERGE, weight = _DEFAULT_WEIGHT, executable_group = _DEFAULT_EXECUTABLE_GROUP):
    """Creates a validated group metadata struct.

    Args:
        rank: Partial ordering key. Lower rank = earlier. Default 0.
        do_not_merge: If True, packager must not merge this group. Default False.
        weight: Merge priority hint (int >= 0 or None). Default None.
        executable_group: If True, the packager should place the executable
            and supporting files into this group. Default False.

    Returns:
        A struct with rank, do_not_merge, weight, and executable_group fields.
    """
    if type(rank) != "int":
        fail("group_metadata: rank must be an int, got ", type(rank))
    if type(do_not_merge) != "bool":
        fail("group_metadata: do_not_merge must be a bool, got ", type(do_not_merge))
    if weight != None:
        if type(weight) != "int":
            fail("group_metadata: weight must be an int or None, got ", type(weight))
        if weight < 0:
            fail("group_metadata: weight must be >= 0, got ", weight)
    if type(executable_group) != "bool":
        fail("group_metadata: executable_group must be a bool, got ", type(executable_group))
    return struct(rank = rank, do_not_merge = do_not_merge, weight = weight, executable_group = executable_group)

_DEFAULT_METADATA = group_metadata()

def _normalize_entry(name, entry):
    if type(entry) == "struct":
        rank = getattr(entry, "rank", _DEFAULT_RANK)
        do_not_merge = getattr(entry, "do_not_merge", _DEFAULT_DO_NOT_MERGE)
        weight = getattr(entry, "weight", _DEFAULT_WEIGHT)
        executable_group = getattr(entry, "executable_group", _DEFAULT_EXECUTABLE_GROUP)
        return group_metadata(rank = rank, do_not_merge = do_not_merge, weight = weight, executable_group = executable_group)
    if type(entry) == "dict":
        return group_metadata(
            rank = entry.get("rank", _DEFAULT_RANK),
            do_not_merge = entry.get("do_not_merge", _DEFAULT_DO_NOT_MERGE),
            weight = entry.get("weight", _DEFAULT_WEIGHT),
            executable_group = entry.get("executable_group", _DEFAULT_EXECUTABLE_GROUP),
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
A dict mapping group name (string) to a struct with rank, do_not_merge, weight, and executable_group fields.
Groups not present get default metadata (rank=0, do_not_merge=False, weight=None, executable_group=False).
""",
    },
)

DEFAULT_METADATA = _DEFAULT_METADATA
