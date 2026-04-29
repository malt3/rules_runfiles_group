# rules_runfiles_group

A Bazel module that enables `*_binary` rules to split their runfiles into named groups and packaging rules to consume those groups as ordered layers. When a binary rule supports `RunfilesGroupInfo`, packaging rules can produce more efficient artifacts: for example, container images with shared base layers or archive formats that separate interpreter, standard library, and application code.

```starlark
# BUILD.bazel
load("@rules_foo//foo:defs.bzl", "foo_binary")
load("@rules_acme_pkg//pkg:defs.bzl", "pkg_tar")

foo_binary(
    name = "app",
    # This binary produces RunfilesGroupInfo with groups like
    # "interpreter", "stdlib", "app_code", "third_party".
    ...
)

pkg_tar(
    name = "app_tar",
    binary = ":app",
    # The packaging rule reads RunfilesGroupInfo, applies ordering,
    # and creates one tar file per group.
)
```

## Table of contents

- [Guidance for users](#guidance-for-users)
- [Guidance for *_binary rule authors](#guidance-for-binary-rule-authors)
- [Guidance for package rule authors](#guidance-for-package-rule-authors)
- [Compatibility](#compatibility)

> **Full worked example:** The [`example/`](example/) directory contains a complete end-to-end demo. Look at [`example/producer/`](example/producer/) for `*_binary` rule implementation, [`example/consumer/`](example/consumer/) for packaging rule implementation, and [`example/src/`](example/src/) for user-facing `BUILD` files.

## Guidance for users

### It just works

You can package any `*_binary` rule. If the rule doesn't support `RunfilesGroupInfo`, packaging rules will still package it using the flat runfiles from `DefaultInfo`. If a ruleset does support `RunfilesGroupInfo`, you'll automatically benefit from smarter layer splitting without any changes to your `BUILD` files.

### Customizing group behavior with `aspect_hints`

Some rulesets offer `aspect_hints` targets as mixins that let you tweak how groups are merged or ordered. For example, a ruleset might provide a target that excludes the interpreter group (because it's already present in the base image):

```starlark
load("@rules_foo//foo:hints.bzl", "skip_interpreter")

skip_interpreter(name = "skip_interpreter")

foo_binary(
    name = "app",
    aspect_hints = [":skip_interpreter"],
    ...
)
```

These mixins work by attaching `RunfilesGroupTransformInfo` or `RunfilesGroupSelectionInfo` providers that packaging rules pick up through aspects. You can combine multiple hints on the same target.

### Advanced: custom aspects

It's also possible to implement custom rules that apply aspects to binary targets to construct `RunfilesGroupInfo` yourself. You could do this to enforce organization-specific layering policies. See the [package rule authors](#for-package-rule-authors) section for the resolution protocol.

---

## Guidance for *_binary rule authors

### When to implement

If splitting runfiles into groups is not a concern for your rule — for example, the binary is a single statically linked executable — you don't have to do anything. Packaging rules will fall back to `DefaultInfo.default_runfiles`.

If your binary does have meaningful groups (interpreter, standard library, first-party code, third-party dependencies, debug symbols, etc.), return `RunfilesGroupInfo` alongside `DefaultInfo` from your rule.

### Ordering with `RunfilesGroupSelectionInfo`

If ordering doesn't matter, you don't need to return `RunfilesGroupSelectionInfo`. Packaging rules will default to lexicographic ordering (or no ordering). 

If you do return a selection, good ordering defaults put foundational or shared content first:

1. Interpreter / runtime
2. Standard library
3. Third-party dependencies
4. First-party application code

This ordering maximizes cache reuse in layered formats — base layers change less frequently than application code.

### Creating groups

There may be different preferences for splitting things into groups. A good way to support this is to create fine-grained groups in `*_library` rules and merge them in `*_binary` rules. Two recommended approaches:

**Bottom-up propagation.** In every `*_library` rule, propagate groups from `deps` and add the current target's files to its own group. The `*_binary` rule collects all groups from deps, optionally merging them (e.g., by repository).

**Aspect-based collection.** Apply an aspect to `deps` in the `*_binary` rule that walks the dependency graph and collects files into groups. This avoids modifying `*_library` rules but requires an aspect implementation.

> **There is no single best grouping.** Different users have different deployment targets. What works for one packaging ruleset or consumer may not work well for others. Prefer producing fine-grained groups by default and let users merge them via `aspect_hints` with `RunfilesGroupTransformInfo`. This way, you provide the raw material and users shape it to their needs. Consider also exposing information about group weights (e.g., file counts or byte sizes) so that packaging rules can implement custom weight-based merging strategies. See [Group count limits](#group-count-limits) below for details.

> [!CAUTION]
> Merging groups by merging their `depset`s is cheap. Calling `.to_list()` on a depset is expensive and should be avoided during analysis. Build group hierarchies purely through `depset(transitive = [...])`.

### Group count limits

Packaging rules may enforce a maximum group count. For example, container image runtimes may limit the total number of layers an image can have. It can make sense to let users specify a maximum group count and merge groups when the limit is exceeded.

To decide which groups to merge, calculate the "weight" of each group. Two recommended approaches:

- **File count proxy.** Use an aspect to count the number of files in each group. This is cheap and works well in practice.
- **Actual file sizes.** In a repository rule, inspect files of third-party repos and annotate `*_library` targets with the actual byte sizes they contribute to their group.

Groups with large weight should be left unmerged. They benefit most from being cached as separate entities. Lightweight groups should be merged first, as combining them has minimal impact on cache efficiency.

### Testing your implementation

Use `runfiles_group_analysis_test` to verify that your `*_binary` rule produces a valid `RunfilesGroupInfo`. The test checks two properties:

1. **Completeness.** The union of all groups must equal `DefaultInfo.default_runfiles.files` exactly — no missing files, no extra files.
2. **Overlap.** It detects files that appear in more than one group. The `overlapping_group_behavior` attribute controls whether overlaps produce warnings (default) or hard failures.

When a check fails, the test prints the target label and lists the offending files so you can trace them back to the rule logic that produced them.

> [!CAUTION]
> This test materializes every depset to compare file sets, making it expensive on large targets. It is meant for rule authors validating their implementation in internal test suites, not for end users running it on every `*_binary` in a production build.

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [
        ":my_binary",
        ":my_other_binary",
    ],
    overlapping_group_behavior = "error",
)
```

---

## Guidance for package rule authors

### Resolution protocol

When resolving runfiles groups from a binary target, follow this well-defined order:

1. **Obtain `RunfilesGroupInfo`:** Extract it from the binary target if present. If any `aspect_hints` target on the binary also provides `RunfilesGroupInfo`, use the last one (it overrides the binary's).

2. **Apply transforms:** Iterate through the binary's `aspect_hints` in order. For each hint that provides `RunfilesGroupTransformInfo`, apply it to the current `RunfilesGroupInfo` using `lib.transform_groups()`.

3. **Determine selection:** Start with the binary's `RunfilesGroupSelectionInfo` (if present). Then iterate `aspect_hints` — the last hint providing `RunfilesGroupSelectionInfo` wins.

4. **Apply ordering:** Call `lib.ordered_groups(runfiles_group_info, selection_info)` to get the final ordered list of `(group_name, depset[File])` tuples.

### Using the library

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo", "RunfilesGroupSelectionInfo", "RunfilesGroupTransformInfo")

# In your aspect implementation:
ordered = lib.ordered_groups(runfiles_group_info, selection_info)
for group_name, files_depset in ordered:
    # Create a layer / archive entry / etc.
    ...
```

### Respecting `aspect_hints`

Apply an aspect to the `binary` attribute. Inside the aspect, read `ctx.rule.attr.aspect_hints` to access the hint targets and their providers. This is the mechanism through which users customize group behavior without modifying the binary rule.

Note that ordering may not matter for some kinds of packages. In that case, it's advised to still perform the selection step `lib.ordered_groups(rgi)`, but ignore ordering of the output.

---

## Compatibility

### Rulesets producing `RunfilesGroupInfo` (*_binary rules)

| Ruleset | Grouping | Ordering | Weight-based merging |
|---------|----------|----------|---------------------|
| *Your ruleset here* | | | |

### Rulesets consuming `RunfilesGroupInfo` (packaging rules)

| Ruleset | Ordering | `aspect_hints` support |
|---------|----------|----------------------|
| *Your ruleset here* | | |

> To add your ruleset to these tables, open a pull request.
