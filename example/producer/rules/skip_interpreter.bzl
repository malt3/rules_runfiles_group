load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load(
    "@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo",
    "RunfilesGroupMetadataInfo",
    "RunfilesGroupTransformInfo",
)

def _skip_interpreter_transform(runfiles_group_info, runfiles_group_metadata_info):
    new_groups = {}
    for group_name in lib.group_names(runfiles_group_info):
        if group_name == "interpreter":
            continue
        new_groups[group_name] = getattr(runfiles_group_info, group_name)

    new_metadata = None
    if runfiles_group_metadata_info != None:
        new_meta_groups = {k: v for k, v in runfiles_group_metadata_info.groups.items() if k != "interpreter"}
        if new_meta_groups:
            new_metadata = RunfilesGroupMetadataInfo(groups = new_meta_groups)

    return struct(
        runfiles_group_info = RunfilesGroupInfo(**new_groups),
        runfiles_group_metadata_info = new_metadata,
    )

def _skip_interpreter_impl(ctx):
    return [
        RunfilesGroupTransformInfo(
            transform = _skip_interpreter_transform,
        ),
    ]

skip_interpreter = rule(
    implementation = _skip_interpreter_impl,
    attrs = {},
)
