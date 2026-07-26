"""Defines provider for transforming resolved runfiles groups.

This provider is intended for use as an aspect_hint on a target
to transform runfiles groups.
"""

_DOC = """\
Information about how to transform a target's resolved runfiles groups.

`transform` takes the value `lib.resolve()` produced -- `struct(groups, by_name,
executable_group)` -- and returns a new one, built with `lib.resolved()`. Edit or
create individual entries with `lib.derive()` and `lib.entry()`. A transform that
changes nothing should `return resolved` unchanged.

It runs once per consuming target, after the entry depset has been flattened
exactly once, so it is pure list and dict work: no depset is rebuilt and no
provider is reconstructed. A transform has no `ctx`, so it cannot build a runfiles
object -- an entry it creates from scratch has to carry a depset of File, which is
`lib.entry()`'s files-only content form.

    def _drop_docs(resolved):
        if not [e for e in resolved.groups if e.kind == "docs"]:
            return resolved
        return lib.resolved(
            [e for e in resolved.groups if e.kind != "docs"],
            executable_group = resolved.executable_group,
        )

`transform` MUST be a module-level `def`, never a lambda or a nested function
created during analysis: a nested function captures a cell per free variable and
pins everything it closes over -- ctx, dep lists, dicts -- for as long as the
provider lives. A module-level def closes only over its module, which Bazel
already retains for the lifetime of the server.
"""

def _make_runfilestransforminfo_init(*, transform):
    if transform == None:
        fail("RunfilesGroupTransformInfo: transform must not be None")
    return {"transform": transform}

RunfilesGroupTransformInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilestransforminfo_init,
    fields = {
        "transform": "A module-level Starlark function (resolved) -> resolved.",
    },
)
