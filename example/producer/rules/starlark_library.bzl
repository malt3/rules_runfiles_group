"""Implementation of the starlark_library rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

_GROUP_PREFIX = "starlark_runfiles_group#"

# All groups produced by this ruleset share a single merge_affinity so that a
# packager forced to merge prefers to keep Starlark groups together (and,
# symmetrically, keeps other rulesets' groups together). Following the
# recommendation, this is the ruleset's identity; a real ruleset would use its
# module name (e.g. "rules_python"). Other modules may reuse this value to opt
# their runfiles groups into the same affinity.
_AFFINITY = "starlark"

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

    # Built once and used both as this library's own group value and as a
    # component of default_runfiles. Allocating a second, identical runfiles
    # object for the group would retain it for nothing.
    own_runfiles = ctx.runfiles(files = direct_srcs)

    # One merge_all instead of a per-dep fold. A fold retains one two-slot array
    # per step -- NestedSet.create stores a child's `children` array, not the
    # child node -- and deepens the artifact DAG once per dep, where merge_all
    # builds a single node and de-dupes identical subsets across all inputs.
    to_merge = [dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps]
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    runfiles = own_runfiles.merge_all(to_merge) if to_merge else own_runfiles

    providers = [
        DefaultInfo(
            files = depset(direct_srcs),
            runfiles = runfiles,
        ),
        StarlarkInfo(
            sources = all_sources,
            loadpath = loadpath,
            repos = repos,
        ),
    ]

    # Honor the global on/off switch: emit no RunfilesGroupInfo when disabled.
    # DefaultInfo and StarlarkInfo are still returned (deps rely on them).
    if not lib.is_enabled(ctx):
        return providers

    group_name = _GROUP_PREFIX + loadpath + ":" + ctx.label.name

    dep_groups = lib.collect_groups(ctx, ctx.attr.deps)
    data_groups = lib.collect_groups(ctx, ctx.attr.data)

    groups = {}
    groups.update(dep_groups.groups)
    groups.update(data_groups.groups)
    groups[group_name] = own_runfiles

    metadata = lib.merge_metadata(dep_groups.metadata, data_groups.metadata)
    own_weight = ctx.attr.runfiles_weight if ctx.attr.runfiles_weight > 0 else None
    own_affinity = ctx.attr.merge_affinity if ctx.attr.merge_affinity else _AFFINITY
    own_metadata = RunfilesGroupMetadataInfo(groups = {
        group_name: lib.group_metadata(weight = own_weight, merge_affinity = own_affinity),
    })
    metadata = lib.merge_metadata(metadata, own_metadata)

    providers.append(RunfilesGroupInfo(**groups))

    # merge_metadata already returned a RunfilesGroupMetadataInfo. Re-wrapping its
    # dict would re-validate every entry for nothing.
    providers.append(metadata)
    return providers


starlark_library = rule(
    implementation = _starlark_library_impl,
    attrs = dict({
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
        "merge_affinity": attr.string(
            default = "",
            doc = """\
Overrides the merge_affinity of this library's runfiles group. If empty
(default), the group uses the ruleset-wide affinity ("starlark") so that all
Starlark groups prefer to merge together. Set this to share an affinity with
another ruleset (the recommendation is to use a module name, e.g. all
JVM-shaped libraries across modules could use "rules_java").
""",
        ),
    }, **lib.RULE_ATTRS),
)
