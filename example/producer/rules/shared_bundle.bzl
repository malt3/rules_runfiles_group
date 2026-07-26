"""Implementation of the shared_bundle rule.

Everything else in the example owns the groups it emits: a per-target group named by
`ctx.label`, or one of the binary's own named groups. This rule covers the other
case the protocol allows -- **several targets contributing to one named group** --
and it covers it with both content forms on purpose.

Contributors to a shared group do not have to agree on a form, and cannot be made
to: a rule whose group is only files hands over the depset it already has, while a
rule that passes on another target's runfiles has no choice but the runfiles object.
`lib.resolve()` folds the two into one group, which is the only place in the
protocol that has to union the forms across producers rather than within one.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")

_AFFINITY = "shared_bundle"

def _shared_bundle_impl(ctx):
    files = depset(ctx.files.srcs, order = "topological")
    runfiles = ctx.runfiles(files = ctx.files.srcs)
    providers = [
        DefaultInfo(
            files = files,
            runfiles = runfiles,
        ),
    ]

    # Honor the global on/off switch: emit no RunfilesGroupInfo when disabled.
    if not lib.is_enabled(ctx):
        return providers

    providers.append(RunfilesGroupInfo(entries = lib.entries([lib.entry(
        # A *named* group, so it needs a ruleset prefix: unlike a Label, a string
        # shares one namespace with every other provider merged into a binary.
        name = ctx.attr.group_name,
        content = files if ctx.attr.content_form == "files" else runfiles,
        kind = "docs",
        merge_affinity = _AFFINITY,
    )])))
    return providers

shared_bundle = rule(
    implementation = _shared_bundle_impl,
    attrs = dict({
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Files this target contributes to the shared group.",
        ),
        "group_name": attr.string(
            mandatory = True,
            doc = "Name of the shared group. Several targets may use the same one.",
        ),
        "content_form": attr.string(
            default = "files",
            values = ["files", "runfiles"],
            doc = """\
Which of lib.entry()'s two content forms to hand over: the depset of File itself
("files", what a files-only group should do) or a runfiles object wrapping it
("runfiles", what a group that carries symlinks or empty filenames has to do).

A real rule has no reason to make this configurable -- it knows which of the two it
is. It exists here so one example binary can be reached by both forms of the same
group.
""",
        ),
    }, **lib.RULE_ATTRS),
)
