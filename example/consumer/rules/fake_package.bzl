"""Consumer rule that resolves runfiles groups from a binary via an aspect."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load(
    "@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo",
    "RunfilesGroupMetadataInfo",
    "RunfilesGroupTransformInfo",
)

# The aspect hands the *providers* to the rule, not lib.ordered_groups()'s
# output. Ordering is O(G log G) and transient; retaining the ordered list would
# keep a list plus one struct per group alive on every packaging target for the
# life of the build.
_FakePackageGroupsInfo = provider(
    doc = "Runfiles groups of a binary after hint metadata and hint transforms.",
    fields = {
        "runfiles_group_info": "RunfilesGroupInfo, after all transforms.",
        "runfiles_group_metadata_info": "RunfilesGroupMetadataInfo or None.",
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

    return [_FakePackageGroupsInfo(
        runfiles_group_info = rgi,
        runfiles_group_metadata_info = metadata,
    )]

_fake_package_aspect = aspect(
    implementation = _fake_package_aspect_impl,
)

def _short_path(file):
    return file.short_path

def _fake_package_impl(ctx):
    groups_info = ctx.attr.binary[_FakePackageGroupsInfo]

    # 4. Apply ordering by rank.
    ordered = lib.ordered_groups(
        groups_info.runfiles_group_info,
        groups_info.runfiles_group_metadata_info,
    )

    # Write the manifest from an Args object rather than a string built during
    # analysis: json.encode(...) over every path materialized an O(all files)
    # string and ctx.actions.write stored it inside the action, retained for the
    # whole build. With Args, only the (already shared) nested sets are held and
    # the file is rendered at execution time.
    #
    # before_each rather than format_each: group names are arbitrary strings and
    # '%' is legal in a label, which would corrupt a format template.
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    for entry in ordered:
        args.add_all(
            entry.runfiles.files,
            before_each = entry.name,
            map_each = _short_path,
            expand_directories = False,
        )

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, args)

    # Build OutputGroupInfo.
    output_groups = {}
    for entry in ordered:
        output_groups[entry.name] = entry.runfiles.files

    return [
        DefaultInfo(files = depset([manifest])),
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
