"""Consumer rule that resolves runfiles groups from a binary via an aspect."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load(
    "@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo",
    "RunfilesGroupMetadataInfo",
    "RunfilesGroupTransformInfo",
)

_FakePackageGroupsInfo = provider(
    doc = "Resolved and ordered runfiles groups from the aspect pipeline.",
    fields = {
        "ordered_groups": "list of struct(name, files, metadata) entries.",
    },
)

def _fake_package_aspect_impl(target, ctx):
    # 1. Obtain RunfilesGroupInfo from the target.
    if RunfilesGroupInfo not in target:
        return []
    rgi = target[RunfilesGroupInfo]

    # 2. Accumulate metadata via dict merge (binary + all hints, last-wins per key).
    metadata = None
    if RunfilesGroupMetadataInfo in target:
        metadata = target[RunfilesGroupMetadataInfo]
    for hint in ctx.rule.attr.aspect_hints:
        if RunfilesGroupMetadataInfo in hint:
            metadata = lib.merge_metadata(metadata, hint[RunfilesGroupMetadataInfo])

    # 3. Apply all transforms (new signature: (rgi, metadata) -> struct).
    for hint in ctx.rule.attr.aspect_hints:
        if RunfilesGroupTransformInfo in hint:
            result = lib.transform_groups(rgi, metadata, hint[RunfilesGroupTransformInfo])
            rgi = result.runfiles_group_info
            metadata = result.runfiles_group_metadata_info

    # 4. Apply ordering by rank.
    ordered = lib.ordered_groups(rgi, metadata)

    return [_FakePackageGroupsInfo(ordered_groups = ordered)]

_fake_package_aspect = aspect(
    implementation = _fake_package_aspect_impl,
)

def _fake_package_impl(ctx):
    groups_info = ctx.attr.binary[_FakePackageGroupsInfo]
    ordered = groups_info.ordered_groups

    # Build JSON debug output (list to preserve order).
    groups_list = []
    for entry in ordered:
        groups_list.append({"group": entry.name, "files": [f.path for f in entry.files.to_list()]})
    json_file = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(json_file, json.encode(groups_list))

    # Build OutputGroupInfo.
    output_groups = {}
    for entry in ordered:
        output_groups[entry.name] = entry.files

    return [
        DefaultInfo(files = depset([json_file])),
        OutputGroupInfo(**output_groups),
    ]

fake_package = rule(
    implementation = _fake_package_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            aspects = [_fake_package_aspect],
            doc = "A binary target providing RunfilesGroupInfo.",
        ),
    },
)
