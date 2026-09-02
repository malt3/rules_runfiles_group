"""Defines the provider that lets an aspect ask a target how it is grouped.

A language ruleset that wants its targets described by somebody else's packaging
rule cannot hand that packager a function through a `load()`: the packager would
need a dependency on every language ruleset it supports. It publishes a handful of
*targets* returning this provider instead, and points its rules at one of them
through the well-known implicit attribute
`@rules_runfiles_group//runfiles_group:callback.bzl%RUNFILES_GROUP_CALLBACK_ATTR`.

This file loads nothing on purpose. It sits on the load path of every build that
uses a participating ruleset's rules, so it must not drag anything else in.
"""

_DOC = """\
How to describe a target's runfiles groups, for an aspect that knows nothing about
the target's language.

`runfiles_group_aspect` reads this provider off the target named by a target's
`_runfiles_group_callback` attribute and calls `describe`. The provider therefore
lives on a handful of configured targets per ruleset -- one per rule family -- and
not on every target of that language.

Fields:

- `describe`: a function `(target, ctx, payload) -> RunfilesGroupInfo | None`.

  `target` is the target being visited and `ctx` is the *aspect's* context, so the
  target's attributes are `ctx.rule.attr` (implicit ones included) and
  `ctx.runfiles()` is available exactly as it is in a rule. Build the entries with
  `runfiles_groups.entry()` and `runfiles_groups.collect()`, the same calls a rule
  would make.

  Returning `None` means "I cannot describe this target": the aspect emits no
  provider, and a packager falls back to `DefaultInfo.default_runfiles` or, for a
  dependency, synthesizes whatever it can. That is a different statement from
  `RunfilesGroupInfo(entries = depset())`, which means "this target is mine and it
  contributes nothing at runtime" -- a `neverlink` library, say. Say the latter
  where it is true, or the caller has to guess, and guessing produces a spurious
  empty group.

  The function MUST be a module-level `def`. A nested function captures a cell per
  free variable and pins everything it closes over for as long as the provider
  lives, which here is the life of the analysis graph.

- `payload`: anything `describe` needs that the aspect cannot see, or `None`.
  Opaque to the aspect, which only hands it back.

  It exists for values reached through *toolchain resolution*. An aspect can only
  resolve a toolchain type it declared at load time, and a language-agnostic aspect
  cannot declare one; the callback target is a rule of the language's own ruleset,
  so it can. It is an implicit dependency of the described target in the same
  configuration, so what it resolves is what the target resolved.
"""

def _make_runfiles_group_callback_info_init(*, describe, payload = None):
    if type(describe) != "function":
        fail(
            "RunfilesGroupCallbackInfo: describe must be a function " +
            "(target, ctx, payload) -> RunfilesGroupInfo | None, got ",
            type(describe),
        )
    return {"describe": describe, "payload": payload}

RunfilesGroupCallbackInfo, _ = provider(
    doc = _DOC,
    init = _make_runfiles_group_callback_info_init,
    fields = {
        "describe": "A module-level Starlark function (target, ctx, payload) -> RunfilesGroupInfo | None.",
        "payload": "Anything describe needs that the aspect cannot see, or None. Opaque to the aspect.",
    },
)
