load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupTransformInfo")

def _skip_interpreter_transform(runfiles_group_info):
    new_groups = {}
    for group_name in dir(runfiles_group_info):
        if group_name == "interpreter":
            continue
        new_groups[group_name] = getattr(runfiles_group_info, group_name)
    return RunfilesGroupInfo(**new_groups)

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
