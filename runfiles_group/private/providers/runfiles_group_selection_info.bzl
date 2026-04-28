"""Defines provider for ordering RunfilesGroupInfo.

Given an instance of RunfilesGroupInfo with an (unordered) set of groups,
RunfilesSelectionInfo can be used to define selection and ordering of groups.
Note: ordering doesn't matter in every context, so RunfilesGroupInfo can stand on it's own.
"""

_DOC = """\
Information about filtering and ordering groups of runfiles.
"""

def _predicate_all(_):
    return True

def _compare_lexicographic(left, right):
    return left < right

def _make_runfilesgroupselectioninfo_init(*, predicate = None, compare = None, group_names = None, extra_group_treatment = None):
    functional = predicate != None or compare != None
    listed = group_names != None or extra_group_treatment != None

    if functional and listed:
        fail("RunfilesGroupSelectionInfo: cannot mix predicate/compare with group_names/extra_group_treatment")
    if not functional and not listed:
        fail("RunfilesGroupSelectionInfo: need either predicate/compare or group_names/extra_group_treatment")

    if listed:
        if group_names == None:
            fail("RunfilesGroupSelectionInfo: group_names is required when extra_group_treatment is set")
        if extra_group_treatment == None:
            extra_group_treatment = "exclude"
        if extra_group_treatment not in ["exclude", "prepend", "append"]:
            fail("extra_group_treatment must be one of exclude, prepend, or append, but got ", extra_group_treatment)

        return {
            "predicate": None,
            "compare": None,
            "group_names": group_names,
            "extra_group_treatment": extra_group_treatment,
        }

    return {
        "predicate": predicate if predicate != None else _predicate_all,
        "compare": compare if compare != None else _compare_lexicographic,
        "group_names": None,
        "extra_group_treatment": None,
    }

RunfilesGroupSelectionInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilesgroupselectioninfo_init,
    fields = {
        "predicate": """\
A starlark function that takes a single string (group name).
The function should return True if the group should be included in the output (and return False otherwise).
Set in functional form, None in list form.
""",
        "compare": """\
A starlark function that takes two strings as input (group names)
and returns True if the first group name should come before the second (and False otherwise).
Set in functional form, None in list form.
""",
        "group_names": """\
A list of group names defining the desired order.
Set in list form, None in functional form.
Mutually exclusive with predicate and compare.
""",
        "extra_group_treatment": """\
How to treat groups not in group_names. One of "exclude", "prepend", or "append".
Set in list form, None in functional form.
""",
    },
)
