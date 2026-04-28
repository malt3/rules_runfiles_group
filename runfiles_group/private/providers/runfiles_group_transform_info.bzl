"""Defines provider for transforming RunfilesGroupInfo by merging groups.

This provider is intended for use as an aspect_hint on a target
to merge some runfiles groups together, producing a new RunfilesGroupInfo
with fewer or different groups.
"""

_DOC = """\
Information about how to transform a RunfilesGroupInfo by merging groups.
"""

def _make_runfilestransforminfo_init(*, transform = None, merge_groups = None, unmatched_group_treatment = None, default_group_name = None):
    functional = transform != None
    dict_form = merge_groups != None or unmatched_group_treatment != None or default_group_name != None

    if functional and dict_form:
        fail("RunfilesGroupTransformInfo: cannot mix transform with merge_groups/unmatched_group_treatment/default_group_name")
    if not functional and not dict_form:
        fail("RunfilesGroupTransformInfo: need either transform or merge_groups/unmatched_group_treatment")

    if dict_form:
        if merge_groups == None:
            fail("RunfilesGroupTransformInfo: merge_groups is required in dict form")
        if unmatched_group_treatment == None:
            unmatched_group_treatment = "keep_separate"
        if unmatched_group_treatment not in ["exclude", "keep_separate", "merge_default"]:
            fail("unmatched_group_treatment must be one of exclude, keep_separate, or merge_default, but got ", unmatched_group_treatment)
        if unmatched_group_treatment == "merge_default":
            if default_group_name == None:
                fail("RunfilesGroupTransformInfo: default_group_name is required when unmatched_group_treatment is merge_default")
        elif default_group_name != None:
            fail("RunfilesGroupTransformInfo: default_group_name is only valid when unmatched_group_treatment is merge_default")

        return {
            "transform": None,
            "merge_groups": merge_groups,
            "unmatched_group_treatment": unmatched_group_treatment,
            "default_group_name": default_group_name,
        }

    return {
        "transform": transform,
        "merge_groups": None,
        "unmatched_group_treatment": None,
        "default_group_name": None,
    }

RunfilesGroupTransformInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilestransforminfo_init,
    fields = {
        "transform": """\
A starlark function that takes a RunfilesGroupInfo and returns a new RunfilesGroupInfo.
Set in functional form, None in dict form.
""",
        "merge_groups": """\
A dict mapping output group name (string) to a list of source group names (list of string).
Each source group's depset is merged into the output group.
Set in dict form, None in functional form.
""",
        "unmatched_group_treatment": """\
How to treat groups not listed in any merge_groups value.
One of "exclude", "keep_separate", or "merge_default".
Defaults to "keep_separate" if omitted. Set in dict form, None in functional form.
""",
        "default_group_name": """\
The name of the group that unmatched groups are merged into.
Required when unmatched_group_treatment is "merge_default", None otherwise.
""",
    },
)
