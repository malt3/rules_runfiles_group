"""The language-agnostic aspect that asks each target how its runfiles are grouped.

See `//runfiles_group:aspect.bzl` for the public API and
`//runfiles_group:callback.bzl` for the protocol this implements.
"""

load("//runfiles_group/private:lib.bzl", "runfiles_groups")
load("//runfiles_group/private/providers:runfiles_group_callback_info.bzl", "RunfilesGroupCallbackInfo")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")

# Kept in sync with //runfiles_group:callback.bzl%RUNFILES_GROUP_CALLBACK_ATTR,
# which is where producing rulesets are pointed at it. Not loaded from there:
# callback.bzl loads this module's providers, so reading the constant back out of
# it would be a cycle.
RUNFILES_GROUP_CALLBACK_ATTR = "_runfiles_group_callback"

# One shared empty list rather than a fresh one per visited target -- this is the
# answer for every target in a build that does not participate.
_NO_PROVIDERS = []

def _describe(target, ctx):
    # No callback attribute means the target's ruleset does not participate.
    # That is not an error -- it is the answer for almost every target in a
    # build -- and a packager falls back to DefaultInfo.default_runfiles.
    callback_target = getattr(ctx.rule.attr, RUNFILES_GROUP_CALLBACK_ATTR, None)
    if callback_target == None:
        return _NO_PROVIDERS

    # This aspect is the only supported way to produce RunfilesGroupInfo, so a
    # participating rule returning one itself is a bug -- and one Bazel would
    # otherwise report as an opaque "provider provided twice" from inside the
    # aspect.
    if RunfilesGroupInfo in target:
        fail(("{}: returns RunfilesGroupInfo itself and also has a '{}' attribute. " +
              "A rule must not return the provider: describe the target from the " +
              "callback target instead, and let runfiles_group_aspect attach it.").format(
            target.label,
            RUNFILES_GROUP_CALLBACK_ATTR,
        ))

    if RunfilesGroupCallbackInfo not in callback_target:
        fail(("{}: its '{}' attribute points at {}, which does not return " +
              "RunfilesGroupCallbackInfo. That attribute name is reserved by " +
              "@rules_runfiles_group//runfiles_group:callback.bzl.").format(
            target.label,
            RUNFILES_GROUP_CALLBACK_ATTR,
            callback_target.label,
        ))

    callback = callback_target[RunfilesGroupCallbackInfo]
    info = callback.describe(target, ctx, callback.payload)

    # None means "not describable", which is not the same as an empty group set --
    # see RunfilesGroupCallbackInfo.describe.
    if info == None:
        return _NO_PROVIDERS
    return [info]

def _gated_aspect_impl(target, ctx):
    if not runfiles_groups.is_enabled(ctx):
        return _NO_PROVIDERS
    return _describe(target, ctx)

def _aspect_impl(target, ctx):
    return _describe(target, ctx)

def make_runfiles_group_aspect(
        *,
        toolchains = [],
        attrs = {},
        attr_aspects = ["*"],
        gated = True,
        doc = ""):
    """Builds an aspect that synthesizes RunfilesGroupInfo from callback targets.

    Most packagers want `runfiles_group_aspect`, the ready-made instance. Use this
    factory when the aspect needs extra attributes or toolchains of its own, or
    when it must ignore the global on/off switch.

    Args:
        toolchains: Toolchain types the aspect requires. Note that this does not
            help a *describe function* reach a language's toolchain: the aspect is
            language-agnostic and cannot know which types to declare. That is what
            `RunfilesGroupCallbackInfo.payload` is for.
        attrs: Extra private attributes for the aspect. Merged with
            `runfiles_groups.RULE_ATTRS` when `gated` is True.
        attr_aspects: Attributes to propagate along. The default `["*"]` is what
            makes a binary's dependencies describable too, which a bottom-up
            producer needs: a describe function calling
            `runfiles_groups.collect()` only sees a dependency's groups if the
            aspect has already visited it.
        gated: Honor the global RunfilesGroupInfo on/off switch
            (`@rules_runfiles_group//runfiles_group:enabled`) and emit nothing
            while it is off. Leave this True unless the aspect is attached by
            something that has already decided groups are wanted.
        doc: Documentation string for the aspect.

    Returns:
        An aspect.
    """
    if gated:
        return aspect(
            implementation = _gated_aspect_impl,
            attr_aspects = attr_aspects,
            attrs = dict(attrs, **runfiles_groups.RULE_ATTRS),
            toolchains = toolchains,
            doc = doc,
        )
    return aspect(
        implementation = _aspect_impl,
        attr_aspects = attr_aspects,
        attrs = attrs,
        toolchains = toolchains,
        doc = doc,
    )

runfiles_group_aspect = make_runfiles_group_aspect(
    doc = """\
Produces RunfilesGroupInfo for targets whose ruleset ships callback targets.

This is the only supported way for a ruleset to produce the provider, so a
packaging rule that does not attach it sees no groups at all. Attach it to the
attribute holding the binary you package, next to whatever other aspects that
attribute already carries. It propagates over every attribute, so the binary's
dependencies are described too, and it honors the global
`@rules_runfiles_group//runfiles_group:enabled` switch.

It emits nothing for a target whose ruleset does not participate -- so a packager
applies it unconditionally and reads the result with `runfiles_groups.resolve()`,
which already returns None when a target carries no groups.
""",
)
