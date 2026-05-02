# rules_runfiles_group

A Bazel module that enables `*_binary` rules to split their runfiles into named groups and packaging rules to consume those groups as (partially) ordered layers. When a binary rule supports `RunfilesGroupInfo`, packaging rules can produce more efficient artifacts: for example, container images with shared base layers or archive formats that separate interpreter, standard library, and application code.

```starlark
# BUILD.bazel
load("@rules_foo//foo:defs.bzl", "foo_binary")
load("@rules_acme_pkg//pkg:defs.bzl", "pkg_creator")

foo_binary(
    name = "app",
    # This binary produces RunfilesGroupInfo with groups like
    # "interpreter", "stdlib", "third_party",  "app_code"
    # ---
    # it could also produce one group per third-party dep:
    # "interpreter", "stdlib", "libfoo", "libbar", "libbaz", "app_code"
    ...
)

pkg_creator(
    name = "app_tar",
    binary = ":app",
    # The packaging rule reads RunfilesGroupInfo,
    # optionally merges groups (see below),
    # applies partial ordering,
    # and creates one package per group.
)
```

## Table of contents

- [Providers at a glance](#providers-at-a-glance)
- [Guidance for users](#guidance-for-users)
- [Guidance for *_binary rule authors](#guidance-for-binary-rule-authors)
- [Guidance for package rule authors](#guidance-for-package-rule-authors)
- [Compatibility](#compatibility)

## Providers at a glance

| Provider | `*_binary` rule | `aspect_hints` | Required | Purpose |
|----------|:-:|:-:|:-:|---------|
| `DefaultInfo` | **must** return | — | yes | Defines the executable and runfiles tree. Used as fallback when `RunfilesGroupInfo` is missing or the consumer doesn't support it. |
| `RunfilesGroupInfo` | may return | — | no | Splits `DefaultInfo.default_runfiles.files` into named groups. |
| `RunfilesGroupMetadataInfo` | may return | may add | no | Per-group metadata (rank, do_not_merge, weight) controlling ordering and merge behavior. |
| `RunfilesGroupTransformInfo` | — | may add | no | Transforms groups and metadata (e.g., exclude a group, remap names). |

> **Full worked example:** The [`example/`](example/) directory contains a complete end-to-end demo. Look at [`example/producer/`](example/producer/) for `*_binary` rule implementation, [`example/consumer/`](example/consumer/) for packaging rule implementation, and [`example/src/`](example/src/) for user-facing `BUILD` files.

## Guidance for users

### It just works

You can package any `*_binary` rule. If the rule doesn't support `RunfilesGroupInfo`, packaging rules will still package it using the flat runfiles from `DefaultInfo`. If a ruleset does support `RunfilesGroupInfo`, you'll automatically benefit from smarter layer splitting without any changes to your `BUILD` files.

### Customizing group behavior with `aspect_hints`

Some rulesets offer `aspect_hints` targets as mixins that let you tweak how groups are transformed or what metadata is attached. For example, a ruleset might provide a target that excludes the interpreter group (because it's already present in the base image):

```starlark
load("@rules_foo//foo:hints.bzl", "skip_interpreter")

skip_interpreter(name = "skip_interpreter")

foo_binary(
    name = "app",
    aspect_hints = [":skip_interpreter"],
    ...
)
```

These mixins work by attaching `RunfilesGroupTransformInfo` or `RunfilesGroupMetadataInfo` providers that packaging rules pick up through aspects. You can combine multiple hints on the same target.

### Advanced: custom aspects

It's also possible to implement custom rules that apply aspects to binary targets to create your own `RunfilesGroupInfo`. You could do this to enforce organization-specific layering policies. See the [package rule authors](#guidance-for-package-rule-authors) section for the resolution protocol.

---

## Guidance for *_binary rule authors

### When to implement

If splitting runfiles into groups is not a concern for your rule — for example, the binary is a single statically linked executable — you don't have to do anything. Packaging rules will fall back to `DefaultInfo.default_runfiles.files`.

If your binary does have meaningful groups (interpreter, standard library, first-party code, third-party dependencies, debug symbols, etc.), return `RunfilesGroupInfo` alongside `DefaultInfo` from your rule.

### Metadata with `RunfilesGroupMetadataInfo`

Return `RunfilesGroupMetadataInfo` alongside `RunfilesGroupInfo` to declare per-group metadata that controls ordering, merge eligibility, and merge priority.

Each group can have:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `rank` | int | 0 | Partial ordering key. Lower rank = earlier in the output. Groups at different ranks are never merged together. |
| `do_not_merge` | bool | False | If True, packaging rules must not merge this group with others. |
| `weight` | int >= 0 or None | None | Hint for merge priority. Lighter groups are merged first when reducing group count. If None, the packager may apply its own default. |

Groups not listed in the metadata dict get default values for all fields (the same applies if `RunfilesGroupMetadataInfo` is missing).

Use the `lib.group_metadata()` helper to create validated metadata entries:

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")

providers.append(RunfilesGroupInfo(**groups))
providers.append(RunfilesGroupMetadataInfo(groups = {
    "interpreter": lib.group_metadata(rank = -2, do_not_merge = True),
    "std": lib.group_metadata(rank = -1),
    "app_code": lib.group_metadata(rank = 0, weight = 100),
}))
```

Good rank defaults put foundational or shared content at lower ranks (negative rank numbers are supported). Note that groups with no ranking will have the default rank `0`, so you are able to place important groups relative to that.
The following types of content should typically use a negative rank:

1. Interpreter / runtime
2. Standard library
3. Third-party dependencies
4. First-party application code

This ordering maximizes cache reuse in layered formats — base layers change less frequently than application code.

Within the same rank, the packager is free to order or merge groups as it sees fit. The partial ordering only guarantees that groups with lower rank appear before groups with higher rank.

### Creating groups

There may be different preferences for splitting files into groups. A good way to support this is to create fine-grained groups in `*_library` rules (and optionally merge them in `*_binary` rules). Two recommended approaches:

**Bottom-up propagation.** In every `*_library` rule, propagate groups from `deps` and add the current target's files to its own group. The `*_binary` rule collects all groups from deps, optionally merging them (e.g., by repository).

**Aspect-based collection.** Apply an aspect to `deps` in the `*_binary` rule that walks the dependency graph and collects files into groups. This avoids modifying `*_library` rules but requires an aspect implementation.

> **There is no single best grouping.** Different users have different deployment targets. What works for one packaging ruleset or consumer may not work well for others. Prefer producing fine-grained groups by default and let users merge them via `aspect_hints` with `RunfilesGroupTransformInfo`. This way, you provide the raw material and users shape it to their needs. Set `weight` on groups to help packaging rules make informed merge decisions.

> [!CAUTION]
> Merging groups by merging their `depset`s is cheap. Calling `.to_list()` on a depset is expensive and should be avoided during analysis. Build group hierarchies purely through `depset(transitive = [...])`.

### Handling `deps` and `data`

Most rules have the attributes `deps` and `data`. You should implement support for them carfully.

**`deps`** typically come from your own ruleset's `*_library` targets — they will likely provide `RunfilesGroupInfo`, so you should merge the groups and metadata with the others.

**`data`** can be arbitrary targets. Some may provide `RunfilesGroupInfo` (e.g., a `*_binary` from a ruleset that supports it), while others won't. Add ungrouped files (when `RunfilesGroupInfo` is missing) to a runfiles group (the default for the current target) so they are not lost.

```starlark
dep_groups = lib.collect_groups(ctx.attr.deps)
data_groups = lib.collect_groups(ctx.attr.data)

groups = {}
groups.update(dep_groups.groups)
groups.update(data_groups.groups)
groups["app_code"] = depset(my_own_files, transitive = data_groups.ungrouped)

metadata = lib.merge_metadata(dep_groups.metadata, data_groups.metadata)
```

### Group count limits

Packaging rules may enforce a maximum group count via `lib.merge_to_limit()`. For example, container image runtimes may limit the total number of layers an image can have. The merge algorithm respects `rank` (only merges within the same rank), `do_not_merge` (never merges protected groups), and `weight` (merges lightest groups first).

Useful weight hints may be language-specific. Good examples include:

- **File count proxy.** Use an aspect to count the number of files in each group. This is cheap and works well in practice.
- **Actual file sizes.** In a repository rule, inspect files of third-party repos and annotate `*_library` targets with the actual byte sizes they contribute to their group.

Groups with large weight are more likely to be left unmerged. They benefit most from being cached as separate entities. Lightweight groups are merged first, as combining them has minimal impact on cache efficiency.

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

1. **Obtain `RunfilesGroupInfo`:** Extract it from the binary target if present. Note: in case `RunfilesGroupInfo` is missing, skip the rest of this protocol and package `DefaultInfo.default_runfiles.files` as a single group instead.

2. **Accumulate metadata:** Start with the binary's `RunfilesGroupMetadataInfo` (if present). Then iterate `aspect_hints` — for each hint providing `RunfilesGroupMetadataInfo`, dict-merge it into the accumulated metadata using `lib.merge_metadata()`. This is per-key last-wins: hints can override metadata for specific groups without affecting others.

3. **Apply transforms:** Iterate through the binary's `aspect_hints` in order. For each hint that provides `RunfilesGroupTransformInfo`, apply it using `lib.transform_groups()`. The transform receives both the current `RunfilesGroupInfo` and `RunfilesGroupMetadataInfo` and returns updated versions of both.

4. **Optionally merge:** If you need to enforce a maximum group count, call `lib.merge_to_limit(runfiles_group_info, metadata_info, max_groups = N)` before ordering. This merges the lightest same-rank groups until the count fits within the limit. Note: packagers may wish to implement their own group merging strategies instead of `lib.merge_to_limit`.

5. **Apply ordering:** Call `lib.ordered_groups(runfiles_group_info, metadata_info)` to get the final ordered list of `(group_name, depset[File])` tuples, sorted by rank.

### Using the library

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo", "RunfilesGroupMetadataInfo", "RunfilesGroupTransformInfo")

# In your aspect implementation:
rgi = target[RunfilesGroupInfo]  # always from the target, never from aspect_hints

# Accumulate metadata from binary + hints
metadata = target[RunfilesGroupMetadataInfo] if RunfilesGroupMetadataInfo in target else None
for hint in ctx.rule.attr.aspect_hints:
    if RunfilesGroupMetadataInfo in hint:
        metadata = lib.merge_metadata(metadata, hint[RunfilesGroupMetadataInfo])

# Apply transforms
for hint in ctx.rule.attr.aspect_hints:
    if RunfilesGroupTransformInfo in hint:
        result = lib.transform_groups(rgi, metadata, hint[RunfilesGroupTransformInfo])
        rgi = result.runfiles_group_info
        metadata = result.runfiles_group_metadata_info

# Order by rank
ordered = lib.ordered_groups(rgi, metadata)
for group_name, files_depset in ordered:
    # Create a layer / archive entry / etc.
    ...

# Or merge first if you have a group limit
result = lib.merge_to_limit(rgi, metadata, max_groups = 5)
ordered = lib.ordered_groups(result.runfiles_group_info, result.runfiles_group_metadata_info)
```

### Respecting `aspect_hints`

Apply an aspect to the `binary` attribute. Inside the aspect, read `ctx.rule.attr.aspect_hints` to access the hint targets and their providers. This is the mechanism through which users customize group behavior without modifying the binary rule.

Note that ordering may not matter for some kinds of packages. In that case, it's advised to still perform the ordering step `lib.ordered_groups(rgi, metadata)`, but treat the intra-rank order as arbitrary.

### Packaging the executable file itself along with other supporting files

`RunfilesGroupInfo` only covers the files inside `DefaultInfo.default_runfiles.files`. A well-behaved packager should also handle the remaining pieces of the executable: the binary file itself, the runfiles symlinks, the repo mapping manifest, etc. These are not part of any runfiles group. It is up to the packager to decide where they go — they could be added to an existing group, placed in a dedicated group, or handled out of band entirely.

---

## Compatibility

### Rulesets producing `RunfilesGroupInfo` (*_binary rules)

| Ruleset | Grouping | Metadata | Weight hints |
|---------|----------|----------|-------------|
| *Your ruleset here* | | | |

### Rulesets consuming `RunfilesGroupInfo` (packaging rules)

| Ruleset | Ordering | Merge-to-limit | `aspect_hints` support |
|---------|----------|----------------|----------------------|
| [rules_img](https://github.com/bazel-contrib/rules_img) | ✅ | ✅ | ✅ |
| *Your ruleset here* | | | |

> To add your ruleset to these tables, open a pull request.
