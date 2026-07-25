"""Implementation of the asset_bundle rule.

This is a deliberately tiny, standalone "ruleset" that has nothing to do with
Starlark. It exists to show that runfiles groups coming from *different*
rulesets carry *different* merge affinities: everything the Starlark rules
produce shares the "starlark" affinity, while every asset_bundle shares the
"asset_bundle" affinity. When a packager is forced to merge groups, it prefers
to keep each ruleset's groups together before mixing across rulesets.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")

_GROUP_PREFIX = "asset_bundle#"

# This ruleset stamps its own module-style affinity on every group it emits.
_AFFINITY = "asset_bundle"

def _asset_bundle_impl(ctx):
    group_name = _GROUP_PREFIX + ctx.label.name
    runfiles = ctx.runfiles(files = ctx.files.srcs)
    providers = [
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = runfiles,
        ),
    ]

    # Honor the global on/off switch: emit no RunfilesGroupInfo when disabled.
    if not lib.is_enabled(ctx):
        return providers

    providers.append(RunfilesGroupInfo(**{group_name: runfiles}))
    providers.append(RunfilesGroupMetadataInfo(groups = {
        group_name: lib.group_metadata(
            rank = lib.RANK_SHARED_DEPS,
            weight = ctx.attr.weight if ctx.attr.weight > 0 else None,
            merge_affinity = _AFFINITY,
        ),
    }))
    return providers

asset_bundle = rule(
    implementation = _asset_bundle_impl,
    attrs = dict({
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Asset files bundled into this group.",
        ),
        "weight": attr.int(
            default = 0,
            doc = "Weight hint for this bundle's runfiles group. If > 0, set as the weight in RunfilesGroupMetadataInfo.",
        ),
    }, **lib.RULE_ATTRS),
)
