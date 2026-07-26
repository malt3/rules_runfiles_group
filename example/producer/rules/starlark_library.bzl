"""Implementation of the starlark_library rule."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

# This rule's group is per-target: it is named by ctx.label, so it needs no
# ruleset name prefix -- a Label cannot collide with another ruleset's group.
# Only starlark_binary produces *named* groups ("interpreter", "std", one per
# repository), and those are the ones that carry a prefix.
#
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

    # One depset for the two things that need this library's own sources: DefaultInfo
    # and the group entry below. The group carries the depset itself rather than a
    # runfiles object, because a Starlark library's group is only ever files -- no
    # symlinks, no empty filenames -- and wrapping it would retain a runfiles object
    # per library target that carries no information the depset does not.
    own_files = depset(direct_srcs)

    # One merge_all instead of a per-dep fold. A fold retains one two-slot array
    # per step -- NestedSet.create stores a child's `children` array, not the
    # child node -- and deepens the artifact DAG once per dep, where merge_all
    # builds a single node and de-dupes identical subsets across all inputs.
    to_merge = [dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps]
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    own_runfiles = ctx.runfiles(transitive_files = own_files)
    runfiles = own_runfiles.merge_all(to_merge) if to_merge else own_runfiles

    providers = [
        DefaultInfo(
            files = own_files,
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

    own_weight = ctx.attr.runfiles_weight if ctx.attr.runfiles_weight > 0 else None
    own_affinity = ctx.attr.merge_affinity if ctx.attr.merge_affinity else _AFFINITY

    # One entry of its own plus the dependencies' entry depsets by reference. No
    # dict, no per-level copy of the transitive group set: the cost of this
    # provider is independent of how many groups the closure contains.
    #
    # The own entry goes through `own =` rather than into a second, wrapping
    # depset, so the depset gains only one level of depth per library rather than
    # two -- which doubles how deep a dependency chain may get before Bazel's
    # nested set depth limit rejects it.
    providers.append(RunfilesGroupInfo(entries = lib.collect(
        ctx,
        deps = ctx.attr.deps,
        data = ctx.attr.data,
        own = [lib.entry(
            # A per-target group: this library's own sources, and nothing else.
            # ctx.label is already interned and globally unique, so it needs no
            # ruleset prefix and costs nothing to name.
            name = ctx.label,
            content = own_files,
            # A library in an external repository is third-party code as far as a
            # packager is concerned; one in this workspace is not.
            kind = "third_party" if ctx.attr.repository else "first_party",
            weight = own_weight,
            merge_affinity = own_affinity,
        )],
    )))
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
            doc = "Weight hint for this library's runfiles group. If > 0, set as the group entry's weight.",
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
