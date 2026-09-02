"""Implementation of the starlark_app rule.

A pluggable application: it composes libraries reached through *five* dependency
attributes, one of each Label-typed attribute kind Bazel offers, because each one
has to say something different:

    main              attr.label                    exactly one entry library
    deps              attr.label_list               plain libraries
    plugins           attr.string_keyed_label_dict  runtime id -> plugin library
    pinned_versions   attr.label_keyed_string_dict  library -> pinned version
    optional_features attr.label_list_dict          feature name -> libraries

All five are *dependency* attributes, so all five go into
`runfiles_groups.collect(deps = )`, which takes an iterable of ctx.attr values and
finds the Targets in each of them whatever shape it has. The ids, versions and feature names are not decoration:
they are written into the app's registry manifest, which is what makes the dict
kinds the right shape rather than a demonstration of them.

`data` is the other half of runfiles_groups.collect() and is handled differently:
a data target without RunfilesGroupInfo gets an entry synthesized for it, where a
`deps` target without one contributes nothing. See the documentation of
runfiles_groups.collect().

attr.label_list_dict is Bazel 9 and newer. On older versions the rule drops
`optional_features` (see _EXTRA_ATTRS below) rather than lose the rest of the
demonstration.
"""

load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

# Same ruleset-wide affinity as starlark_library/starlark_binary: an app's own
# group belongs with the rest of the Starlark groups under merge pressure.
_AFFINITY = "starlark"

# attr.label_list_dict arrived in Bazel 9. Probing for it keeps this example
# loadable on 7 and 8, where the rule simply has no `optional_features`
# attribute -- and the macro below drops what a BUILD file passes for it, so one
# BUILD file works on every version.
HAS_LABEL_LIST_DICT = hasattr(attr, "label_list_dict")

_EXTRA_ATTRS = {
    "optional_features": attr.label_list_dict(
        providers = [StarlarkInfo],
        doc = "Feature name -> the libraries that implement it.",
    ),
} if HAS_LABEL_LIST_DICT else {}

def _loadpath(target):
    return target[StarlarkInfo].loadpath

def _dep_attrs(attrs):
    """Every dependency attribute, in the shape ctx.attr hands it over.

    This is the list runfiles_groups.collect() walks: one element per attribute,
    and it finds the Targets inside each -- the Target itself, a list of them, or
    whichever side of a dict carries them.
    """
    return [
        attrs.main,
        attrs.deps,
        attrs.plugins,
        attrs.pinned_versions,
        getattr(attrs, "optional_features", {}),
    ]

def _starlark_app_impl(ctx):
    optional_features = getattr(ctx.attr, "optional_features", {})

    # The same dependencies as _dep_attrs, flattened by hand rather than by asking
    # the protocol for them. Spelling it out is the point: DefaultInfo below is
    # built from *this* list and the groups from _dep_attrs, so a bug in the
    # attribute walking shows up as files that are in default_runfiles and in no
    # group -- which is exactly what runfiles_group_analysis_test checks. Sharing
    # one flattening between the two would make that check agree with itself and
    # prove nothing.
    dep_targets = [ctx.attr.main] + ctx.attr.deps + ctx.attr.plugins.values() + ctx.attr.pinned_versions.keys()
    for targets in optional_features.values():
        dep_targets += targets

    # The registry the app loads at runtime: which plugin answers to which id,
    # which libraries a named feature pulls in, and the pinned version of every
    # vendored library. The dict attributes exist for these three lines.
    registry = ctx.actions.declare_file(ctx.label.name + ".registry.json")
    ctx.actions.write(registry, json.encode(struct(
        main = _loadpath(ctx.attr.main),
        deps = [_loadpath(dep) for dep in ctx.attr.deps],
        plugins = {plugin_id: _loadpath(dep) for plugin_id, dep in ctx.attr.plugins.items()},
        pinned = {str(dep.label): version for dep, version in ctx.attr.pinned_versions.items()},
        features = {
            feature: [_loadpath(dep) for dep in targets]
            for feature, targets in optional_features.items()
        },
    )))

    # One depset for the two things that need the app's own files, exactly as
    # starlark_library does it: DefaultInfo, and the group the describe function
    # reads back off it.
    own_files = depset([registry])

    # One merge_all rather than a per-dep fold. See starlark_library.bzl.
    to_merge = [dep[DefaultInfo].default_runfiles for dep in dep_targets]
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    own_runfiles = ctx.runfiles(transitive_files = own_files)

    return [
        DefaultInfo(
            files = own_files,
            runfiles = own_runfiles.merge_all(to_merge),
        ),
        StarlarkInfo(
            sources = depset(transitive = [dep[StarlarkInfo].sources for dep in dep_targets]),
            loadpath = "//" + ctx.label.package,
            repos = depset(transitive = [dep[StarlarkInfo].repos for dep in dep_targets]),
        ),
    ]

def _starlark_app_groups(target, ctx, _payload):
    """Describes a starlark_app's runfiles as groups.

    Args:
        target: The starlark_app being described.
        ctx: The aspect context.
        _payload: Unused; this callback carries none.

    Returns:
        RunfilesGroupInfo.
    """

    # One call for all five dependency attributes plus data. A library reached
    # through two of them -- a plugin that is also a plain dep, say -- propagates
    # the same entry depset twice, and the fold collapses the duplicate group back
    # into one.
    return RunfilesGroupInfo(entries = runfiles_groups.collect(
        ctx,
        deps = _dep_attrs(ctx.rule.attr),
        data = [ctx.rule.attr.data],
        own = [runfiles_groups.entry(
            name = target.label,
            content = target[DefaultInfo].files,
            kind = "first_party",
            merge_affinity = _AFFINITY,
        )],
    ))

def _starlark_app_callback_impl(_ctx):
    return [RunfilesGroupCallbackInfo(describe = _starlark_app_groups)]

starlark_app_runfiles_group_callback = rule(
    implementation = _starlark_app_callback_impl,
    doc = "Publishes how a starlark_app's runfiles are grouped.",
    provides = [RunfilesGroupCallbackInfo],
)

_starlark_app = rule(
    implementation = _starlark_app_impl,
    attrs = dict({
        "main": attr.label(
            providers = [StarlarkInfo],
            mandatory = True,
            doc = "The app's entry library. Exactly one, so attr.label.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "Libraries the app always loads.",
        ),
        "plugins": attr.string_keyed_label_dict(
            providers = [StarlarkInfo],
            doc = "Runtime plugin id -> the library implementing it.",
        ),
        "pinned_versions": attr.label_keyed_string_dict(
            providers = [StarlarkInfo],
            doc = "Vendored library -> the version recorded for it in the registry.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "_runfiles_group_callback": attr.label(
            default = Label("//producer/rules:starlark_app_callback"),
        ),
    }, **_EXTRA_ATTRS),
)

def starlark_app(name, optional_features = None, **kwargs):
    """Assembles a pluggable Starlark app from its libraries.

    A macro only so that a BUILD file can pass `optional_features` on every Bazel
    version: attr.label_list_dict, the kind that attribute needs, is Bazel 9 and
    newer, and on older versions the feature libraries are dropped.

    Args:
        name: Target name.
        optional_features: Feature name -> the libraries implementing it. Ignored
            on Bazel 8 and older.
        **kwargs: The rule's other attributes.
    """
    if optional_features and HAS_LABEL_LIST_DICT:
        kwargs["optional_features"] = optional_features
    _starlark_app(name = name, **kwargs)
