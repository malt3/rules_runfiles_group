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
| `RunfilesGroupInfo` | may return | — | no | Splits `DefaultInfo.default_runfiles` into named runfiles groups. |
| `RunfilesGroupMetadataInfo` | may return | may add | no | Per-group metadata (rank, do_not_merge, weight, executable_group, merge_affinity) controlling ordering, merge behavior, executable placement, and merge grouping. |
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

### Honoring the global on/off switch

`RunfilesGroupInfo` (and its metadata) costs a little extra memory on every target that emits it. When no packaging rule in a build consumes those providers, that cost is wasted. `rules_runfiles_group` exposes a single global flag — shared by every producing ruleset — that gates emission. It defaults to **off**, so a build pays for the providers only when it opts in:

```console
# No RunfilesGroupInfo emitted (the default):
bazel build //...
# Emit RunfilesGroupInfo everywhere it is supported:
bazel build //... --@rules_runfiles_group//runfiles_group:enabled=true
```

Because the flag defaults to `False`, no providers are emitted out of the box. A build that packages with a rule which consumes `RunfilesGroupInfo` should turn the flag on — most conveniently in its `.bazelrc`, so every command picks it up:

```
# .bazelrc
common --@rules_runfiles_group//runfiles_group:enabled=true
```

Rule authors honor the flag with two pieces from `lib`, which are **a pair**:

1. Merge `lib.RULE_ATTRS` into your rule's `attrs`. This adds a private `_runfiles_group_enabled` attribute pointing at the flag. You don't name the flag yourself — the label is resolved in the `rules_runfiles_group` repo context, so it points at `@rules_runfiles_group//runfiles_group:enabled` automatically in your repo.
2. Gate provider emission on `lib.is_enabled(ctx)`, returning early before doing any grouping work.

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")

_MY_BINARY_ATTRS = {
    # ... your rule's own attributes ...
}

my_binary = rule(
    implementation = _my_binary_impl,
    # dict(..., **lib.RULE_ATTRS) works on all supported Bazel versions;
    # _MY_BINARY_ATTRS | lib.RULE_ATTRS is equivalent on newer Starlark.
    attrs = dict(_MY_BINARY_ATTRS, **lib.RULE_ATTRS),
    executable = True,
)

def _my_binary_impl(ctx):
    providers = [DefaultInfo(...)]

    if not lib.is_enabled(ctx):
        return providers  # emit no RunfilesGroupInfo when globally disabled

    # ... build groups, then append RunfilesGroupInfo / RunfilesGroupMetadataInfo ...
    return providers
```

> A rule that calls `lib.is_enabled(ctx)` **must** have merged `lib.RULE_ATTRS` into its `attrs`; otherwise the read of the `_runfiles_group_enabled` attribute fails. Put the gate at the very top of the RunfilesGroupInfo-producing code path so that when disabled there is no `ctx.runfiles(...)`, no `lib.collect_groups(...)`, and no provider construction.

### Metadata with `RunfilesGroupMetadataInfo`

Return `RunfilesGroupMetadataInfo` alongside `RunfilesGroupInfo` to declare per-group metadata that controls ordering, merge eligibility, and merge priority.

Each group can have:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `rank` | int | 0 | Partial ordering key. Lower rank = earlier in the output. Groups at different ranks are never merged together. |
| `do_not_merge` | bool | False | If True, packaging rules must not merge this group with others. |
| `weight` | int >= 0 or None | None | Hint for merge priority. Lighter groups are merged first when reducing group count. If None, the packager may apply its own default. |
| `executable_group` | bool | False | If True, signals that the packager should place the executable file, repo mapping manifest, and other supporting files for the main entrypoint into this group. Only meaningful at the top level — `collect_groups` strips this bit by default (see below). |
| `merge_affinity` | str | `""` | Best-effort merge grouping hint. When groups must be merged, groups that share the same `merge_affinity` are preferred merge partners (see [Group count limits](#group-count-limits)). The empty string `""` means "no affinity". |

Groups not listed in the metadata dict get default values for all fields (the same applies if `RunfilesGroupMetadataInfo` is missing).

Use the `lib.group_metadata()` helper to create validated metadata entries:

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl",
    "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")

providers.append(RunfilesGroupInfo(**groups))
providers.append(RunfilesGroupMetadataInfo(groups = {
    "foo_runfiles_group#interpreter": lib.group_metadata(
        rank = lib.RANK_FOUNDATION, do_not_merge = True, merge_affinity = "rules_foo"),
    "foo_runfiles_group#std": lib.group_metadata(
        rank = lib.RANK_FOUNDATION + 100, merge_affinity = "rules_foo"),
    "foo_runfiles_group#app_code": lib.group_metadata(
        rank = lib.RANK_EXECUTABLE, weight = 100, executable_group = True, merge_affinity = "rules_foo"),
}))
```

#### Recommended rank values

Ranks form a partial order: lower rank = earlier layer = the content that changes
least often and is shared most widely. Negative ranks sort before the default rank
of `0`, so foundational content ends up in the earliest (most cacheable) layers.

Use these anchors, exposed as constants for convenience:

| Constant | Value | Use for |
|----------|-------|---------|
| `lib.RANK_FOUNDATION` | `-1000` | Foundational, rarely-changing content shared by many binaries: language runtimes, interpreters, standard libraries. |
| `lib.RANK_SHARED_DEPS` | `-100` | Third-party dependencies shared across binaries. |
| `lib.RANK_EXECUTABLE` | `0` | The executable and first-party application code. Also the default rank for groups without explicit metadata. |

The anchors are spaced far apart on purpose: there is ample room to slot finer
sub-tiers in between without renumbering everything. For example, an interpreter
might sit at `RANK_FOUNDATION` while the standard library sits at
`RANK_FOUNDATION + 100` — both foundational, but strictly ordered.

This ordering maximizes cache reuse in layered formats — base layers change less
frequently than application code.

Within the same rank, the packager is free to order or merge groups as it sees fit. The partial ordering only guarantees that groups with lower rank appear before groups with higher rank.

#### Grouping merges with `merge_affinity`

`merge_affinity` is a best-effort hint that steers *which* groups get merged when a
packager must reduce the group count (see [Group count limits](#group-count-limits)).
Groups that share the same `merge_affinity` are preferred merge partners; merging
only crosses affinities when no same-affinity pair remains.

**Recommendation: use your module name as the affinity, and stamp it on every group
your ruleset produces.** This keeps a ruleset's groups together under merge pressure
instead of being interleaved with unrelated groups. Affinities are a shared namespace,
so other modules may deliberately reuse a value to opt into the same grouping — for
example, `rules_java` could be the affinity for all JVM-shaped groups, including those
contributed by `rules_jvm_external`, Kotlin rules, and other Java-flavored rulesets.

The empty string `""` means "no affinity". Auto-generated `data#<label>` groups (data
deps that do not themselves provide `RunfilesGroupInfo`) are never assigned an affinity
— they keep the empty affinity `""`.

### Creating groups

There may be different preferences for splitting files into groups. A good way to support this is to create fine-grained groups in `*_library` rules (and optionally merge them in `*_binary` rules). Two recommended approaches:

**Bottom-up propagation.** In every `*_library` rule, propagate groups from `deps` and add the current target's runfiles to its own group. The `*_binary` rule collects all groups from deps, optionally merging them (e.g., by repository).

**Aspect-based collection.** Apply an aspect to `deps` in the `*_binary` rule that walks the dependency graph and collects runfiles into groups. This avoids modifying `*_library` rules but requires an aspect implementation.

> **There is no single best grouping.** Different users have different deployment targets. What works for one packaging ruleset or consumer may not work well for others. Prefer producing fine-grained groups by default and let users merge them via `aspect_hints` with `RunfilesGroupTransformInfo`. This way, you provide the raw material and users shape it to their needs. Set `weight` on groups to help packaging rules make informed merge decisions.

> [!CAUTION]
> Merging groups via `runfiles.merge()` is cheap (uses depset transitive under the hood). Calling `.to_list()` on a depset is expensive and should be avoided during analysis. Build group hierarchies purely through `runfiles.merge()` and `runfiles.merge_all()`.

### Naming groups

Group names are arbitrary strings and live in a shared namespace across all `RunfilesGroupInfo` providers merged into the same binary. If two rulesets independently define a group called `"interpreter"` — say, one for Node.js and one for Python — those groups will be merged together, which may be undesirable.

To avoid this, **prefix all group names with a string unique to your ruleset**, separated by a delimiter like `#`:

```starlark
groups["my_rules_runfiles_group#interpreter"] = ctx.runfiles(files = [...])
groups["my_rules_runfiles_group#std"] = ctx.runfiles(files = [...])
groups["my_rules_runfiles_group#" + loadpath + ":" + ctx.label.name] = ctx.runfiles(files = [...])
```

This ensures that `my_rules_runfiles_group#interpreter` and `other_rules_runfiles_group#interpreter` remain distinct, even when both rulesets contribute groups to the same binary target.

When merging groups (e.g., in `merge_to_limit`), pass a custom `merged_group_name` callback that strips the prefix from the second group name before joining. This keeps merged names readable — `my_rules_runfiles_group#foo+bar` instead of `my_rules_runfiles_group#foo+my_rules_runfiles_group#bar`.

### Handling `deps` and `data`

Most rules have the attributes `deps` and `data`. You should implement support for them carefully.

**`deps`** typically come from your own ruleset's `*_library` targets — they will likely provide `RunfilesGroupInfo`, so you should merge the groups and metadata with the others.

**`data`** can be arbitrary targets. Some may provide `RunfilesGroupInfo` (e.g., a `*_binary` from a ruleset that supports it), while others won't. For targets without `RunfilesGroupInfo`, `collect_groups` automatically creates a named group `data#<canonical label>` whose value is a runfiles combining `DefaultInfo.files` and `DefaultInfo.default_runfiles`. This means that if two parts of the dependency graph share the same data dep, they produce the same group name — the binary-level dict merge naturally deduplicates the group so the data dep's files are recorded only once. These auto-generated `data#` groups carry no metadata, so they keep the default empty `merge_affinity` (`""`): a data dep that does not itself provide `RunfilesGroupInfo` is never assigned an affinity.

By default, `collect_groups` strips the `executable_group` bit from all collected metadata entries. This is the correct behavior for `data` deps: when a binary appears as a data dependency of another binary, its `executable_group` annotation is meaningless because the outer binary has its own entrypoint. The top-level `*_binary` target should set `executable_group` on its own group instead.

```starlark
dep_groups = lib.collect_groups(ctx, ctx.attr.deps)
data_groups = lib.collect_groups(ctx, ctx.attr.data)

groups = {}
groups.update(dep_groups.groups)
groups.update(data_groups.groups)
groups["foo_runfiles_group#app_code"] = ctx.runfiles(files = my_own_files)

metadata = lib.merge_metadata(dep_groups.metadata, data_groups.metadata)
# executable_group has been stripped from dep metadata by collect_groups.
# Set it (and our ruleset-wide merge_affinity) on our own group instead:
metadata = lib.merge_metadata(metadata, RunfilesGroupMetadataInfo(groups = {
    "foo_runfiles_group#app_code": lib.group_metadata(executable_group = True, merge_affinity = "rules_foo"),
}))
```

### Group count limits

Packaging rules may enforce a maximum group count via `lib.merge_to_limit()`. For example, container image runtimes may limit the total number of layers an image can have. The merge algorithm respects `rank` (only merges within the same rank), `do_not_merge` (never merges protected groups), `merge_affinity` (prefers same-affinity partners), and `weight` (merges lightest groups first).

Concretely, `merge_to_limit` picks each merge in this order:

1. **Same rank only.** Groups at different ranks are never merged.
2. **Prefer same `merge_affinity`.** Among same-rank candidates, it first considers pairs that share a `merge_affinity` (the empty string `""` is the shared "no affinity" bucket). It only falls back to merging across affinities when no same-affinity pair remains at any rank.
3. **Lightest first.** Within the preferred set, the two lightest groups (by `weight`) merge first.

This means a ruleset that stamps its module name as the `merge_affinity` on all its groups will see those groups consolidated together under merge pressure, rather than interleaved with unrelated groups — even when an interleaved merge would be marginally cheaper by weight.

Useful weight hints may be language-specific. Good examples include:

- **File count proxy.** Use an aspect to count the number of files in each group. This is cheap and works well in practice.
- **Actual file sizes.** In a repository rule, inspect files of third-party repos and annotate `*_library` targets with the actual byte sizes they contribute to their group.

Groups with large weight are more likely to be left unmerged. They benefit most from being cached as separate entities. Lightweight groups are merged first, as combining them has minimal impact on cache efficiency.

### Testing your implementation

Use `runfiles_group_analysis_test` to verify that your `*_binary` rule produces a valid `RunfilesGroupInfo`. Every binary is analyzed in **two configurations** via a split transition, so a single test target covers three properties:

1. **Completeness.** For each runfiles component (files, empty_filenames, symlinks, root_symlinks), the union of all groups must equal the corresponding component of `DefaultInfo.default_runfiles` exactly — no missing entries, no extra entries.
2. **Overlap.** It detects entries that appear in more than one group (per component). The `overlapping_group_behavior` attribute controls whether overlaps produce warnings (default) or hard failures.
3. **Honoring the global switch.** With `@rules_runfiles_group//runfiles_group:enabled` set to `False`, the binary must provide neither `RunfilesGroupInfo` nor `RunfilesGroupMetadataInfo`. Checks 1 and 2 run in the branch where the flag is `True`. Because the transition pins both branches, the test result does not depend on the flag's value on the command line.

When a check fails, the test prints the target label, which of the two configurations failed, and lists the offending files so you can trace them back to the rule logic that produced them.

> [!CAUTION]
> This test materializes every depset to compare file sets, making it expensive on large targets, and it analyzes each binary twice. It is meant for rule authors validating their implementation in internal test suites, not for end users running it on every `*_binary` in a production build.

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

4. **Optionally merge:** If you need to enforce a maximum group count, call `lib.merge_to_limit(runfiles_group_info, metadata_info, max_groups = N)` before ordering. This merges same-rank groups until the count fits within the limit, preferring same-`merge_affinity` partners and merging the lightest groups first (see [Group count limits](#group-count-limits)). Note: packagers may wish to implement their own group merging strategies instead of `lib.merge_to_limit`.

5. **Apply ordering:** Call `lib.ordered_groups(runfiles_group_info, metadata_info)` to get the final ordered list of `struct(name, runfiles, metadata)` entries, sorted by rank. Each entry has `name` (string), `runfiles` (a runfiles object), and `metadata` (the group's metadata struct, or None if no explicit metadata was set for that group). When a group has `metadata.executable_group == True`, the packager should add the executable file, repo mapping manifest, and other supporting files for the main entrypoint to that group's runfiles.

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
for entry in ordered:
    # entry.name: group name (string)
    # entry.runfiles: runfiles object
    # entry.metadata: group_metadata struct or None
    if entry.metadata and entry.metadata.executable_group:
        # Add executable, runfiles symlinks, repo mapping manifest
        # to this group's layer.
        ...
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

`RunfilesGroupInfo` only covers the runfiles inside `DefaultInfo.default_runfiles`. A well-behaved packager should also handle the remaining pieces of the executable: the binary file itself, the runfiles symlinks, the repo mapping manifest, etc. These are not part of any runfiles group.

When a group's metadata has `executable_group = True`, the packager should add these supporting files to that group. This is the `*_binary` rule's way of saying "this is where my entrypoint lives." If no group is marked `executable_group`, the packager decides where to place them — they could be added to an existing group, placed in a dedicated group, or handled out of band entirely.

The `executable_group` bit is only meaningful at the top level. When a binary appears as a `data` dependency of another binary, the outer binary has its own entrypoint. For this reason, `lib.collect_groups()` strips `executable_group` from collected metadata by default. The `*_binary` rule should set `executable_group` on its own group rather than inheriting it from deps.

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
