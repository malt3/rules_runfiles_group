"""Defines provider for transforming RunfilesGroupInfo and RunfilesGroupMetadataInfo.

This provider is intended for use as an aspect_hint on a target
to transform runfiles groups, producing new RunfilesGroupInfo
and RunfilesGroupMetadataInfo instances.
"""

_DOC = """\
Information about how to transform a RunfilesGroupInfo (and its metadata).

The transform function receives (RunfilesGroupInfo, RunfilesGroupMetadataInfo_or_None)
and must return a struct with two fields:
- runfiles_group_info: the transformed RunfilesGroupInfo
- runfiles_group_metadata_info: the transformed RunfilesGroupMetadataInfo (or None)
"""

def _make_runfilestransforminfo_init(*, transform):
    if transform == None:
        fail("RunfilesGroupTransformInfo: transform must not be None")
    return {"transform": transform}

RunfilesGroupTransformInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilestransforminfo_init,
    fields = {
        "transform": """\
A starlark function (RunfilesGroupInfo, RunfilesGroupMetadataInfo_or_None) ->
struct(runfiles_group_info, runfiles_group_metadata_info).
""",
    },
)
