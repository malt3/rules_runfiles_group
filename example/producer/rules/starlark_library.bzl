"""Implementation of the starlark_library rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

def _canonical_repo_name(ctx):
    return ctx.label.repo_name or "_main"

def _starlark_library_impl(ctx):
    direct_srcs = ctx.files.srcs

    transitive_sources = [dep[StarlarkInfo].sources for dep in ctx.attr.deps]
    all_sources = depset(direct_srcs, transitive = transitive_sources)

    transitive_repos = [dep[StarlarkInfo].repos for dep in ctx.attr.deps]
    current_repo = _canonical_repo_name(ctx)
    repos = depset([(ctx.attr.repository, current_repo)], transitive = transitive_repos)

    if ctx.attr.repository:
        loadpath = "@" + ctx.attr.repository + "//" + ctx.label.package
    else:
        loadpath = "//" + ctx.label.package

    runfiles = ctx.runfiles(files = direct_srcs + ctx.files.data)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    for dep in ctx.attr.data:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    group_name = loadpath + ":" + ctx.label.name

    groups = {}
    for dep in ctx.attr.deps:
        if RunfilesGroupInfo in dep:
            for name in lib.group_names(dep[RunfilesGroupInfo]):
                groups[name] = getattr(dep[RunfilesGroupInfo], name)

    groups[group_name] = depset(direct_srcs + ctx.files.data)

    metadata = None
    for dep in ctx.attr.deps:
        if RunfilesGroupMetadataInfo in dep:
            metadata = lib.merge_metadata(metadata, dep[RunfilesGroupMetadataInfo])

    own_weight = ctx.attr.runfiles_weight if ctx.attr.runfiles_weight > 0 else None
    own_metadata = RunfilesGroupMetadataInfo(groups = {
        group_name: lib.group_metadata(weight = own_weight),
    })
    metadata = lib.merge_metadata(metadata, own_metadata)

    return [
        DefaultInfo(
            files = depset(direct_srcs),
            runfiles = runfiles,
        ),
        StarlarkInfo(
            sources = all_sources,
            loadpath = loadpath,
            repos = repos,
        ),
        RunfilesGroupInfo(**groups),
        RunfilesGroupMetadataInfo(groups = metadata.groups),
    ]

starlark_library = rule(
    implementation = _starlark_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".star", ".bzl"],
            doc = "Starlark source files.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "Other starlark_library targets.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "repository": attr.string(
            default = "",
            doc = "Repository name for the load path. If empty, loadpath is '//package'. If set, loadpath is '@repository//package'.",
        ),
        "runfiles_weight": attr.int(
            default = 0,
            doc = "Weight hint for this library's runfiles group. If > 0, set as the weight in RunfilesGroupMetadataInfo.",
        ),
    },
)
