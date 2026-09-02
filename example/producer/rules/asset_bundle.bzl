"""Implementation of the asset_bundle rule.

This is a deliberately tiny, standalone "ruleset" that has nothing to do with
Starlark. It exists to show two things: that runfiles groups coming from
*different* rulesets carry *different* merge affinities, and that two rulesets can
both name their per-target groups by Label without any risk of collision -- there
is no prefix to agree on, because a Label is already unique.

It also shows how little a leaf rule has to do to participate: one attribute on
the rule, one describe function, and one callback target.
"""

load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")

# This ruleset stamps its own module-style affinity on every group it describes.
_AFFINITY = "asset_bundle"

def _asset_bundle_impl(ctx):
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
    ]

def _asset_bundle_groups(target, ctx, _payload):
    """Describes an asset_bundle's runfiles as one per-target group.

    Args:
        target: The asset_bundle being described.
        ctx: The aspect context.
        _payload: Unused; this callback carries none.

    Returns:
        RunfilesGroupInfo.
    """

    # A leaf: one per-target group of its own, nothing to collect. The group keeps
    # the runfiles form deliberately, even though its contents are only files: it
    # hands over the object DefaultInfo already retains, so nothing extra is
    # allocated -- and it keeps a second content form in circulation, which is what
    # exercises the protocol's mixed unions when a packager merges these groups
    # with a starlark_library's files-only ones.
    return RunfilesGroupInfo(entries = runfiles_groups.entries([runfiles_groups.entry(
        name = target.label,
        content = target[DefaultInfo].default_runfiles,
        kind = "first_party",
        rank = runfiles_groups.RANK_SHARED_DEPS,
        weight = ctx.rule.attr.weight if ctx.rule.attr.weight > 0 else None,
        merge_affinity = _AFFINITY,
    )]))

def _asset_bundle_callback_impl(_ctx):
    return [RunfilesGroupCallbackInfo(describe = _asset_bundle_groups)]

asset_bundle_runfiles_group_callback = rule(
    implementation = _asset_bundle_callback_impl,
    doc = "Publishes how an asset_bundle's runfiles are grouped.",
    provides = [RunfilesGroupCallbackInfo],
)

asset_bundle = rule(
    implementation = _asset_bundle_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Asset files bundled into this group.",
        ),
        "weight": attr.int(
            default = 0,
            doc = "Weight hint for this bundle's runfiles group. If > 0, set as the group entry's weight.",
        ),
        "_runfiles_group_callback": attr.label(
            default = Label("//producer/rules:asset_bundle_callback"),
        ),
    },
)
