"""Generates synthetic library closures for retained-heap measurement.

The point of these targets is to make the *bookkeeping* cost of the runfiles
group providers visible while holding the file payload constant: every generated
library shares one source file, so no `Artifact` or `NestedSet` payload grows
with `n`. What grows is the number of group entries a target's providers hold.

`stress_closure(name, n)` emits `n` `starlark_library` targets where `lib0` has
no deps and `libI` depends on `libI-1` and `libI-2`. Every library is therefore
in the transitive closure of every later one, so with the flat bottom-up copy
`libI` holds `I+1` groups and the whole closure holds `n*(n+1)/2` group entries.
A design whose per-target cost is independent of the closure size keeps the last
library's retained bytes flat as `n` grows; the flat-copy design doubles it when
`n` doubles. That difference is what `tools/heap_budget.py` asserts, over the last
library of each closure.

Each closure is also capped with a `by_target` binary (which materializes one group
per transitive library) and a packaging target. The CI guard does not measure those,
but they are there to be measured by hand -- `by_target` is the shape where a
consumer re-materializes a name per group.

Everything is tagged `manual`: these targets exist to be measured explicitly,
never as part of `bazel build //...`.
"""

load("//consumer/rules:fake_package.bzl", "fake_package")
load("//producer/rules:starlark_binary.bzl", "starlark_binary")
load("//producer/rules:starlark_library.bzl", "starlark_library")

def stress_closure(name, n, src = "stress.star"):
    """Emits an n-deep library closure plus a binary and a package on top of it.

    Args:
        name: Name of the binary. Libraries are named `<name>_lib<i>`, the
            packaging target `<name>_pkg`.
        n: Number of libraries. Must be >= 1.
        src: Source file shared by every generated target.
    """
    if n < 1:
        fail("stress_closure: n must be >= 1, got ", n)

    for i in range(n):
        deps = []
        if i >= 1:
            deps.append(":{}_lib{}".format(name, i - 1))
        if i >= 2:
            deps.append(":{}_lib{}".format(name, i - 2))
        starlark_library(
            name = "{}_lib{}".format(name, i),
            srcs = [src],
            deps = deps,
            tags = ["manual"],
        )

    starlark_binary(
        name = name,
        src = src,
        # by_target keeps one group per transitive library, which is the shape
        # that makes the flat copy quadratic.
        runfiles_grouping = "by_target",
        tags = ["manual"],
        deps = [":{}_lib{}".format(name, n - 1)],
    )

    fake_package(
        name = name + "_pkg",
        binary = ":" + name,
        tags = ["manual"],
    )
