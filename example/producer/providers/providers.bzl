"""Providers for Starlark source files."""

StarlarkInfo = provider(
    doc = "A depset of Starlark source files needed at runtime.",
    fields = {
        "sources": "depset of File objects containing Starlark source files.",
        "loadpath": "string load path prefix for this library (e.g. '//src' or '@myrepo//src').",
        "repos": "depset of (friendly_name, canonical_name) tuples mapping repository names.",
    },
)

StarlarkBinaryInfo = provider(
    doc = """\
What starlark_binary's runfiles group describe function needs and cannot reach on
its own.

A describe function runs inside an aspect, so it sees the target's providers and
`ctx.rule.attr` -- and nothing else. Anything the rule *computed* has to be
published, or it is invisible: the loadmap and the properties file below are
declared with ctx.actions.declare_file and appear in no attribute.

`interpreter_runfiles` is published for a second reason. The rule could be
recomputed from `ctx.rule.attr.interpreter`, but then the interpreter group's
contents and the interpreter's contribution to default_runfiles would be two
objects that merely happen to agree today. Handing over the one the rule merged
makes them the same object, so they cannot drift.

Contrast `RunfilesGroupCallbackInfo.payload`, which covers the other blind spot:
values that only *toolchain resolution* can supply, which no target-level provider
can carry because the aspect cannot declare the toolchain type.
""",
    fields = {
        "entrypoint_files": "depset of File: the launcher stub, the entrypoint source, the loadmap and the properties file.",
        "interpreter_runfiles": "runfiles: the interpreter executable and its own runfiles, as merged into default_runfiles.",
    },
)
