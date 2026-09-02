"""Implementation of the shared_bundle rule.

Everything else in the example owns the groups it describes: a per-target group
named by the target's label, or one of the binary's own named groups. This rule
covers the other case the protocol allows -- **several targets contributing to one
named group** -- and it covers it with both content forms on purpose.

Contributors to a shared group do not have to agree on a form, and cannot be made
to: a rule whose group is only files hands over the depset it already has, while a
rule that passes on another target's runfiles has no choice but the runfiles object.
`runfiles_groups.resolve()` folds the two into one group, which is the only place
in the protocol that has to union the forms across producers rather than within
one.
"""

load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")

_AFFINITY = "shared_bundle"

def _shared_bundle_impl(ctx):
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs, order = "topological"),
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
    ]

def _shared_bundle_groups(target, ctx, _payload):
    """Describes a shared_bundle's contribution to a named group.

    Args:
        target: The shared_bundle being described.
        ctx: The aspect context.
        _payload: Unused; this callback carries none.

    Returns:
        RunfilesGroupInfo.
    """
    default_info = target[DefaultInfo]
    return RunfilesGroupInfo(entries = runfiles_groups.entries([runfiles_groups.entry(
        # A *named* group, so it needs a ruleset prefix: unlike a Label, a string
        # shares one namespace with every other provider merged into a binary.
        name = ctx.rule.attr.group_name,
        # DefaultInfo.files is deliberately topologically ordered here, which
        # ctx.runfiles(transitive_files = ) rejects -- the protocol launders every
        # depset it is handed into default order, and this is what exercises it.
        content = default_info.files if ctx.rule.attr.content_form == "files" else default_info.default_runfiles,
        kind = "docs",
        merge_affinity = _AFFINITY,
    )]))

def _shared_bundle_callback_impl(_ctx):
    return [RunfilesGroupCallbackInfo(describe = _shared_bundle_groups)]

shared_bundle_runfiles_group_callback = rule(
    implementation = _shared_bundle_callback_impl,
    doc = "Publishes how a shared_bundle's runfiles are grouped.",
    provides = [RunfilesGroupCallbackInfo],
)

shared_bundle = rule(
    implementation = _shared_bundle_impl,
    attrs = {
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
Which of runfiles_groups.entry()'s two content forms to hand over: the depset of
File itself ("files", what a files-only group should do) or a runfiles object
wrapping it
("runfiles", what a group that carries symlinks or empty filenames has to do).

A real rule has no reason to make this configurable -- it knows which of the two it
is. It exists here so one example binary can be reached by both forms of the same
group.
""",
        ),
        "_runfiles_group_callback": attr.label(
            default = Label("//producer/rules:shared_bundle_callback"),
        ),
    },
)
