"""Public API for the runfiles group callback protocol.

A packaging ruleset attaches `runfiles_group_aspect` (see
`@rules_runfiles_group//runfiles_group:aspect.bzl`) to the attribute holding the
binary it packages. For every target in the closure, the aspect looks for an
attribute named `RUNFILES_GROUP_CALLBACK_ATTR`, reads `RunfilesGroupCallbackInfo`
off the target it points at, and calls that provider's `describe` function. The
packager never learns which language it is looking at, and needs no dependency on
any language ruleset.

A **producing** ruleset therefore writes two things:

1. A handful of targets returning `RunfilesGroupCallbackInfo` -- one per rule
   family, so that dispatch is by which target a rule points at rather than by
   `ctx.rule.kind`, which is only a name another ruleset may reuse.
2. `"_runfiles_group_callback": attr.label(default = Label("//..."))` on each of
   its rules, pointing at the matching callback target.

Note the second one spells the attribute name out rather than loading
`RUNFILES_GROUP_CALLBACK_ATTR` from here, and that is deliberate: a rule `.bzl`
that loads `@rules_runfiles_group` gains a load-time dependency on this module,
which is exactly what a language ruleset in Bazel's WORKSPACE autoload set cannot
afford (bazelbuild/bazel#23043). The constant exists so that the name has one
normative home, and so a producing ruleset can assert its hardcoded spelling
against it from a test, where loading this file costs nothing.
"""

load(
    "//runfiles_group/private/providers:runfiles_group_callback_info.bzl",
    _RunfilesGroupCallbackInfo = "RunfilesGroupCallbackInfo",
)

RunfilesGroupCallbackInfo = _RunfilesGroupCallbackInfo

# The well-known name of the implicit attribute pointing at a target's callback
# target. Part of the protocol, not of any one ruleset: `runfiles_group_aspect`
# looks for exactly this name on every rule it visits.
RUNFILES_GROUP_CALLBACK_ATTR = "_runfiles_group_callback"
