"""An aspect_hints mixin that drops the interpreter group.

Users add it to a binary's aspect_hints when the interpreter is already present in
the base image, so the packager should not ship it again.
"""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupTransformInfo")

_INTERPRETER = "starlark_runfiles_group#interpreter"

# A module-level def, never a lambda or a nested def: a function created during
# analysis captures a cell per free variable and pins everything it closes over --
# ctx, dep lists, dicts -- for as long as the provider lives.
def _skip_interpreter_transform(resolved):
    if _INTERPRETER not in resolved.by_name:
        # Nothing to do: hand back the input rather than rebuilding it.
        return resolved

    # Fails loudly if the interpreter group happened to carry the executable,
    # instead of silently dropping the entrypoint's supporting files.
    return runfiles_groups.resolved(
        [entry for entry in resolved.groups if entry.name != _INTERPRETER],
        executable_group = resolved.executable_group,
    )

def _skip_interpreter_impl(_ctx):
    return [
        RunfilesGroupTransformInfo(
            transform = _skip_interpreter_transform,
        ),
    ]

skip_interpreter = rule(
    implementation = _skip_interpreter_impl,
    attrs = {},
)
