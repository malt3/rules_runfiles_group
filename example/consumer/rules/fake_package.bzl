"""Consumer rule that resolves runfiles groups from a binary via an aspect."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load(
    "@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo",
    "RunfilesGroupSelectionInfo",
    "RunfilesGroupTransformInfo",
)

_FakePackageGroupsInfo = provider(
    doc = "Resolved and ordered runfiles groups from the aspect pipeline.",
    fields = {
        "ordered_groups": "list of (group_name, depset[File]) tuples.",
    },
)

def _fake_package_aspect_impl(target, ctx):
    # 1. Obtain RunfilesGroupInfo: from target, overridden by last aspect_hint.
    rgi = None
    if RunfilesGroupInfo in target:
        rgi = target[RunfilesGroupInfo]
    for hint in ctx.rule.attr.aspect_hints:
        if RunfilesGroupInfo in hint:
            rgi = hint[RunfilesGroupInfo]

    if rgi == None:
        return []

    # 2. Apply all transforms from aspect_hints.
    for hint in ctx.rule.attr.aspect_hints:
        if RunfilesGroupTransformInfo in hint:
            rgi = lib.transform_groups(rgi, hint[RunfilesGroupTransformInfo])

    # 3. Find the last selection from [target, ...aspect_hints].
    selection = None
    if RunfilesGroupSelectionInfo in target:
        selection = target[RunfilesGroupSelectionInfo]
    for hint in ctx.rule.attr.aspect_hints:
        if RunfilesGroupSelectionInfo in hint:
            selection = hint[RunfilesGroupSelectionInfo]

    # 4. Apply ordering.
    ordered = lib.ordered_groups(rgi, selection)

    return [_FakePackageGroupsInfo(ordered_groups = ordered)]

_fake_package_aspect = aspect(
    implementation = _fake_package_aspect_impl,
)

def _fake_package_impl(ctx):
    groups_info = ctx.attr.binary[_FakePackageGroupsInfo]
    ordered = groups_info.ordered_groups

    # Build JSON debug output (list to preserve order).
    groups_list = []
    for name, files_depset in ordered:
        groups_list.append({"group": name, "files": [f.path for f in files_depset.to_list()]})
    json_file = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(json_file, json.encode(groups_list))

    # Build OutputGroupInfo.
    output_groups = {}
    for name, files_depset in ordered:
        output_groups[name] = files_depset

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
