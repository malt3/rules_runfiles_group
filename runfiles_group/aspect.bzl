"""Public API for the language-agnostic runfiles group aspect.

`runfiles_group_aspect` is what a packaging rule attaches to the attribute holding
the binary it packages. For every target in that binary's closure it reads the
target's `_runfiles_group_callback` attribute and asks the target it points at to
describe the target's runfiles groups -- so the packager supports every
participating language ruleset without depending on any of them. See
`//runfiles_group:callback.bzl` for the protocol.
"""

load(
    "//runfiles_group/private:aspect.bzl",
    _make_runfiles_group_aspect = "make_runfiles_group_aspect",
    _runfiles_group_aspect = "runfiles_group_aspect",
)

runfiles_group_aspect = _runfiles_group_aspect
make_runfiles_group_aspect = _make_runfiles_group_aspect
