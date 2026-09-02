"""Implementation of the starlark_library rule."""

load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

# This rule's group is per-target: it is named by the target's label, so it needs
# no ruleset name prefix -- a Label cannot collide with another ruleset's group.
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

    # One depset for the two things that need this library's own sources:
    # DefaultInfo, and the group the describe function below builds -- which reads
    # it back off DefaultInfo rather than rebuilding it, so the two cannot drift.
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

    # No RunfilesGroupInfo here, and no global-switch check: a rule does not
    # produce the provider. runfiles_group_aspect does, out of the describe
    # function below, and it is the aspect that honors the switch.
    return [
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

def _starlark_library_groups(target, ctx, _payload):
    """Describes a starlark_library's runfiles as groups.

    Called by runfiles_group_aspect, so `ctx` is the aspect's: the library's
    attributes are ctx.rule.attr and ctx.runfiles() works as it does in a rule.

    Args:
        target: The starlark_library being described.
        ctx: The aspect context.
        _payload: Unused; this callback carries none.

    Returns:
        RunfilesGroupInfo.
    """
    attrs = ctx.rule.attr

    # One entry of its own plus the dependencies' entry depsets by reference. No
    # dict, no per-level copy of the transitive group set: the cost of this
    # provider is independent of how many groups the closure contains.
    #
    # The own entry goes through `own =` rather than into a second, wrapping
    # depset, so the depset gains only one level of depth per library rather than
    # two -- which doubles how deep a dependency chain may get before Bazel's
    # nested set depth limit rejects it.
    return RunfilesGroupInfo(entries = runfiles_groups.collect(
        ctx,
        # Each of deps and data is an iterable of ctx.attr values, so a rule with
        # several Label-typed attributes collects from all of them in one call.
        # This rule has one of each, and they are handled differently: a `deps`
        # target without RunfilesGroupInfo contributes nothing, where a `data` one
        # gets an entry synthesized for it.
        deps = [attrs.deps],
        data = [attrs.data],
        own = [runfiles_groups.entry(
            # A per-target group: this library's own sources, and nothing else.
            # target.label is already interned and globally unique, so it needs no
            # ruleset prefix and costs nothing to name.
            name = target.label,
            # The depset DefaultInfo already holds, not a runfiles object wrapping
            # it: a Starlark library's group is only ever files -- no symlinks, no
            # empty filenames -- and the wrapper would retain one object per
            # library carrying nothing the depset does not.
            content = target[DefaultInfo].files,
            # A library in an external repository is third-party code as far as a
            # packager is concerned; one in this workspace is not.
            kind = "third_party" if attrs.repository else "first_party",
            weight = attrs.runfiles_weight if attrs.runfiles_weight > 0 else None,
            merge_affinity = attrs.merge_affinity if attrs.merge_affinity else _AFFINITY,
        )],
    ))

def _starlark_library_callback_impl(_ctx):
    return [RunfilesGroupCallbackInfo(describe = _starlark_library_groups)]

# The one target every starlark_library points at through its
# `_runfiles_group_callback` attribute. One configured target for the whole
# ruleset, rather than a provider on every library.
starlark_library_runfiles_group_callback = rule(
    implementation = _starlark_library_callback_impl,
    doc = "Publishes how a starlark_library's runfiles are grouped.",
    provides = [RunfilesGroupCallbackInfo],
)

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
        # The well-known attribute name specified by
        # @rules_runfiles_group//runfiles_group:callback.bzl%RUNFILES_GROUP_CALLBACK_ATTR.
        # This is the whole of a ruleset's opt-in: runfiles_group_aspect finds this
        # attribute, takes RunfilesGroupCallbackInfo off the target it names, and
        # calls the describe function. A rule without the attribute is simply not
        # describable, and a packager falls back to DefaultInfo.default_runfiles.
        "_runfiles_group_callback": attr.label(
            default = Label("//producer/rules:starlark_library_callback"),
        ),
    },
)
