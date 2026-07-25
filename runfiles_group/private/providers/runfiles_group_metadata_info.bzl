"""Defines provider for per-group metadata overrides.

Producers put a group's metadata directly on its entry (`lib.entry()`). This
provider carries *overrides*, keyed by group name, for a party that does not own
the group -- in practice an `aspect_hints` mixin that wants to re-rank, protect or
re-affiliate a group produced by someone else.

Because a hint target's provider instance is shared by reference across every
target that lists it, the cost is O(number of hints), never O(targets x groups).
"""

load(":runfiles_group_entry_info.bzl", "KINDS")

_DOC = """\
Per-group metadata overrides, keyed by group name.

Each value is a *patch*: only the fields it actually carries are applied, and every
other field of the group's entry is left untouched. Build one with
`lib.group_metadata(...)`, passing just the fields you want to change:

    RunfilesGroupMetadataInfo(groups = {
        "some_ruleset#interpreter": lib.group_metadata(rank = -2000),
    })

Overridable fields:

- rank (int): partial ordering key. Lower rank = earlier.
- do_not_merge (bool): if True, packagers must not merge this group.
- weight (int >= 0 or None): merge priority hint. Lighter groups merge first.
- kind (str): one of lib.KINDS. A stable selector for packagers.
- merge_affinity (str): merge grouping hint. "" means no affinity.
- executable_group (bool): if True, this group receives the executable and its
  supporting files. Setting it on one group moves it there; setting it to False on
  the group that currently holds it clears it.

Names that match no group are ignored, so a hint can be attached to targets that
do not all produce the same groups.
"""

# Fields a patch may carry. `executable_group` is not a property of an entry -- it
# lives on RunfilesGroupInfo as a single group name -- but it is patchable here so
# that a hint can move the entrypoint.
ENTRY_PATCH_FIELDS = ["rank", "do_not_merge", "weight", "kind", "merge_affinity"]
PATCH_FIELDS = ENTRY_PATCH_FIELDS + ["executable_group"]

# The metadata a group has when nothing overrides it. Exported as the reference
# default for consumers; entries themselves always carry explicit values.
DEFAULT_METADATA = struct(
    rank = 0,
    do_not_merge = False,
    weight = None,
    kind = "",
    merge_affinity = "",
)

def _validate_field(where, name, value):
    if name == "rank":
        if type(value) != "int":
            fail("{}: rank must be an int, got {}".format(where, type(value)))
    elif name == "do_not_merge" or name == "executable_group":
        if type(value) != "bool":
            fail("{}: {} must be a bool, got {}".format(where, name, type(value)))
    elif name == "weight":
        if value != None:
            if type(value) != "int":
                fail("{}: weight must be an int or None, got {}".format(where, type(value)))
            if value < 0:
                fail("{}: weight must be >= 0, got {}".format(where, value))
    elif name == "kind":
        if value not in KINDS:
            fail("{}: kind must be one of {}, got {}".format(where, KINDS, repr(value)))
    elif name == "merge_affinity":
        if type(value) != "string":
            fail("{}: merge_affinity must be a string, got {}".format(where, type(value)))

def group_metadata(**kwargs):
    """Creates a validated metadata patch carrying only the fields passed.

    Args:
        **kwargs: any subset of rank, do_not_merge, weight, kind, merge_affinity
            and executable_group.

    Returns:
        A struct with exactly the fields that were passed.
    """
    for name in kwargs:
        if name not in PATCH_FIELDS:
            fail("group_metadata: unknown field '{}', expected one of {}".format(name, PATCH_FIELDS))
        _validate_field("group_metadata", name, kwargs[name])
    return struct(**kwargs)

def _normalize_entry(name, entry):
    where = "RunfilesGroupMetadataInfo patch for group '{}'".format(name)
    if type(entry) == "struct":
        # Identity fast path: a patch is validated in place and handed back as the
        # SAME object, so a hint's struct is shared by reference by every target
        # that reads it instead of being rebuilt per target. Rebuilding cannot be
        # recovered from: schemaless structs are never interned, and structs
        # nested in a dict are never reached by Bazel's provider compaction.
        for field in PATCH_FIELDS:
            if hasattr(entry, field):
                _validate_field(where, field, getattr(entry, field))
        return entry
    if type(entry) == "dict":
        patch = {}
        for field in entry:
            if field not in PATCH_FIELDS:
                fail("{}: unknown field '{}', expected one of {}".format(where, field, PATCH_FIELDS))
            _validate_field(where, field, entry[field])
            patch[field] = entry[field]
        return struct(**patch)
    fail("{} must be a struct or dict, got {}".format(where, type(entry)))

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
A dict mapping group name (string) to a metadata patch struct carrying any subset of
rank, do_not_merge, weight, kind, merge_affinity and executable_group.
Fields a patch does not carry are left unchanged. Names matching no group are ignored.
""",
    },
)
