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
- [Memory](#memory)
- [Compatibility](#compatibility)

## Providers at a glance

| Provider | `*_binary` rule | `aspect_hints` | Required | Purpose |
|----------|:-:|:-:|:-:|---------|
| `DefaultInfo` | **must** return | — | yes | Defines the executable and runfiles tree. Used as fallback when `RunfilesGroupInfo` is missing or the consumer doesn't support it. |
| `RunfilesGroupInfo` | may return | — | no | Splits `DefaultInfo.default_runfiles` into named runfiles groups, and names the group that carries the executable. |
| `RunfilesGroupMetadataInfo` | rarely | may add | no | Per-group metadata *overrides* for groups you don't own. Producers put metadata directly on their groups instead. |
| `RunfilesGroupTransformInfo` | — | may add | no | Transforms the resolved group set (e.g. exclude a group, remap names). |

`RunfilesGroupInfo` has two fields:

```starlark
RunfilesGroupInfo(
    entries = <depset of group entries, each built with lib.entry()>,
    executable_group = <group name, or None>,
)
```

Each entry carries its own name, runfiles and metadata, so a target propagates its
dependencies' groups by *referencing* their depsets rather than copying them. That
is what keeps a target's cost independent of how many groups its transitive closure
contains — see [Memory](#memory).

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

`RunfilesGroupInfo` costs a little extra memory on every target that emits it. When no packaging rule in a build consumes it, that cost is wasted. `rules_runfiles_group` exposes a single global flag — shared by every producing ruleset — that gates emission. It defaults to **off**, so a build pays for the provider only when it opts in:

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

    # ... build entries, then append RunfilesGroupInfo ...
    return providers
```

> A rule that calls `lib.is_enabled(ctx)` **must** have merged `lib.RULE_ATTRS` into its `attrs`; otherwise the read of the `_runfiles_group_enabled` attribute fails. Put the gate at the very top of the RunfilesGroupInfo-producing code path so that when disabled there is no `ctx.runfiles(...)`, no `lib.collect(...)`, and no provider construction.

### Creating groups

`lib.entry()` is the only supported way to build a group entry, and it validates everything:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Label or str | — | The group's identity: a `Label` for a per-target group, a prefixed string for a group many targets contribute to — see [Naming groups](#naming-groups). |
| `runfiles` | runfiles | — | The group's contents. |
| `kind` | str | `""` | One of `lib.KINDS`. A stable, machine-readable selector for packagers. Does **not** affect ordering or merging. |
| `rank` | int | 0 | Partial ordering key. Lower rank = earlier in the output. Groups at different ranks are never merged together. |
| `do_not_merge` | bool | False | If True, packaging rules must not merge this group with others. |
| `weight` | int >= 0 or None | None | Hint for merge priority. Lighter groups are merged first when reducing group count. If None, the packager may apply its own default. |
| `merge_affinity` | str | `""` | Best-effort merge grouping hint. Groups that share the same `merge_affinity` are preferred merge partners (see [Group count limits](#group-count-limits)). The empty string `""` means "no affinity". |

A leaf rule with one group of its own:

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")

def _asset_bundle_impl(ctx):
    runfiles = ctx.runfiles(files = ctx.files.srcs)
    providers = [DefaultInfo(files = depset(ctx.files.srcs), runfiles = runfiles)]
    if not lib.is_enabled(ctx):
        return providers

    # Reuse the same runfiles object DefaultInfo carries: the group then costs a
    # pointer rather than a second copy of the same nested sets.
    providers.append(RunfilesGroupInfo(entries = lib.entries([lib.entry(
        name = ctx.label,  # a per-target group: no prefix needed
        runfiles = runfiles,
        kind = "first_party",
        rank = lib.RANK_SHARED_DEPS,
        merge_affinity = "asset_bundle",
    )])))
    return providers
```

There are two recommended ways to build up a graph of groups.

**Bottom-up propagation.** In every `*_library` rule, hand your own entries and your
dependencies to `lib.collect()`. It contributes your entries directly and references
your dependencies' depsets, so this is O(1) in the size of the closure:

```starlark
providers.append(RunfilesGroupInfo(entries = lib.collect(
    ctx,
    deps = ctx.attr.deps,
    data = ctx.attr.data,
    own = [lib.entry(
        name = ctx.label,
        runfiles = own_runfiles,
        kind = "first_party",
    )],
)))
```

**Aspect-based collection.** Apply an aspect to `deps` in the `*_binary` rule that walks the dependency graph and collects entries. This avoids modifying `*_library` rules but requires an aspect implementation.

> **There is no single best grouping.** Different users have different deployment targets. What works for one packaging ruleset or consumer may not work well for others. Prefer producing fine-grained groups by default and let users merge them via `aspect_hints` with `RunfilesGroupTransformInfo`. This way, you provide the raw material and users shape it to their needs. Set `weight` on groups to help packaging rules make informed merge decisions.

> [!CAUTION]
> Never call `.to_list()` on a depset in a `*_library` rule — not on runfiles and not on `RunfilesGroupInfo.entries`. `lib.collect()` never flattens anything; `lib.resolve()` does, and it belongs in the packaging rule (or in a `*_binary` rule that genuinely has to re-shape its dependencies' groups, at most once per target).

> [!CAUTION]
> Merging runfiles in a loop is **not** free. `rf = rf.merge(x)` per dependency retains one two-element array per step and deepens the artifact graph once per dependency. Accumulate a list and call `runfiles.merge_all(list)` once instead — it builds a single node and de-duplicates identical inputs across all of them.

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

Assign such a derived rank to a **module-level constant** rather than computing it in
your rule implementation: Bazel only caches small integers, so `lib.RANK_FOUNDATION + 100`
evaluated per target allocates a boxed integer per target and retains it.

This ordering maximizes cache reuse in layered formats — base layers change less
frequently than application code.

Within the same rank, the packager is free to order or merge groups as it sees fit. The partial ordering only guarantees that groups with lower rank appear before groups with higher rank.

#### Classifying groups with `kind`

`kind` is the protocol's stable selector. A group name is either a Label or a
ruleset-internal prefixed string, so a packager configuration keyed on a group name
breaks as soon as a target is renamed. `kind` does not, which makes it the right thing
for a packager's user-facing "include these / exclude those / put these in that layer"
options.

`lib.KINDS` is a closed set: `""` (unspecified), `"foundation"`, `"third_party"`,
`"first_party"`, `"debug"`, `"docs"`. It deliberately has **no** effect on ordering or
merging — that is what `rank` and `merge_affinity` are for.

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

The empty string `""` means "no affinity". The per-target groups synthesized for data
deps that do not themselves provide `RunfilesGroupInfo` are never assigned an affinity
— they keep the empty affinity `""`.

### Naming groups

There are two kinds of group, and a group's name says which kind it is.

**One group per target** — "the runfiles this one target contributes". Name it with a
**Label**: `ctx.label` for your own group, `dep.label` for a dependency's. A Label is
globally unique, so there is no prefix to invent and no namespace to coordinate; two
rulesets that both produce a per-target group cannot collide. It is also free — Bazel
already interns every Label, so naming a group this way allocates nothing, where a
string derived from the label allocates one per target.

```starlark
lib.entry(name = ctx.label, runfiles = own_runfiles, kind = "first_party")
```

**Many targets contributing to one group** — "interpreter", "std", "third_party",
"one group per repository". Here no single target owns the group, so name it with a
**string**. Strings share one namespace across every `RunfilesGroupInfo` merged into
a binary, so **prefix them with something unique to your ruleset**, separated by a
delimiter like `#`. Without that, one ruleset's `"interpreter"` and another's fold
into a single group.

```starlark
lib.entry(name = "my_rules#interpreter", runfiles = ...)
lib.entry(name = "my_rules#std", runfiles = ...)
```

Both forms are ordered, folded, merged and looked up the same way, and
`resolved.by_name` is keyed by whichever form the producer used. Wherever you need a
plain string — an artifact name, an `OutputGroupInfo` key, a manifest line, an error
message — call `lib.name_str(entry)`; for a packager whose user-facing configuration
names groups as strings, `lib.index_by_name_str(resolved)` gives you a
`dict[str, entry]`.

```starlark
for entry in resolved.groups:
    output_groups[lib.name_str(entry.name)] = entry.runfiles.files
```

When merging groups (e.g. in `lib.limit`), the `merged_group_name` callback receives
the names in their original form and may return either. A merged group is rarely
still one target's, so returning a string is the usual answer; use `lib.name_str()`
on the inputs to build it.

Two entries with the *same* name — either form — are legal and are folded into one
group by `lib.resolve()`: their runfiles are unioned, `rank` takes the minimum,
`do_not_merge` is or-ed, `weight` takes the maximum, and `kind` and `merge_affinity`
take whichever is set. This is what makes a shared data dependency collapse to one
group no matter how many targets reach it.

### Marking the group that carries the executable

`RunfilesGroupInfo` only covers the runfiles inside `DefaultInfo.default_runfiles`. A
well-behaved packager also has to place the remaining pieces of an executable
somewhere: the runfiles symlinks, the repo mapping manifest, and so on. Set
`executable_group` to the name of the group where they belong:

```starlark
RunfilesGroupInfo(
    entries = lib.entries(entries),
    executable_group = "foo_runfiles_group#app_code",  # or a Label, for a per-target group
)
```

`lib.resolve()` fails if `executable_group` names no surviving group, so this cannot
silently go stale after a rename or a merge. If it is `None`, the packager decides
where those files go.

It is only meaningful on the **top-level** target. `lib.collect()` never propagates a
dependency's `executable_group`, so a binary that appears as a `data` dependency of
another binary cannot claim the outer binary's entrypoint.

### Handling `deps` and `data`

Most rules have the attributes `deps` and `data`. `lib.collect()` takes both, and both
are mandatory keywords, because handling `data` is the classic footgun here — pass
`data = []` explicitly if your rule has none.

**`deps`** typically come from your own ruleset's `*_library` targets — they will likely provide `RunfilesGroupInfo`, so their entry depsets are referenced directly.

**`data`** can be arbitrary targets. Some may provide `RunfilesGroupInfo` (e.g. a `*_binary` from a ruleset that supports it), while others won't. For targets without `RunfilesGroupInfo`, `lib.collect` synthesizes a per-target entry named by the dep's `Label`, covering its `DefaultInfo.files` and `DefaultInfo.default_runfiles`. Because the name *is* the label, two parts of the dependency graph that share the same data dep produce the same group, and `lib.resolve()` folds them back into one. These synthesized entries carry no `kind` and no `merge_affinity`: a data dep that does not itself provide `RunfilesGroupInfo` is never assigned one.

Two things a `data` dep must not do, because `lib.collect` cannot work around either:

- Publish `DefaultInfo(files = depset(..., order = "topological"))` or `"preorder"`.
  `ctx.runfiles(transitive_files = ...)` accepts only `"default"` and `"postorder"`, and
  Starlark can neither read a depset's order back nor change it, so this fails analysis.
- Rely on its executable being inside its own `default_runfiles`. Bazel merges the executable
  in for Starlark rules, but a native one — a single-output `genrule`, for instance — publishes
  an empty `default_runfiles` alongside a perfectly good `files_to_run.executable`. If your rule
  puts a dependency's executable in a group, put the *same* runfiles object into
  `default_runfiles`, rather than assuming the dependency already did.

### Group count limits

Packaging rules may enforce a maximum group count via `lib.limit()`. For example, container image runtimes may limit the total number of layers an image can have. The merge algorithm respects `rank` (only merges within the same rank), `do_not_merge` (never merges protected groups), `merge_affinity` (prefers same-affinity partners), and `weight` (merges lightest groups first).

Concretely, `lib.limit` picks each merge in this order:

1. **Same rank only.** Groups at different ranks are never merged.
2. **Prefer same `merge_affinity`.** Among same-rank candidates, it first considers pairs that share a `merge_affinity` (the empty string `""` is the shared "no affinity" bucket). It only falls back to merging across affinities when no same-affinity pair remains at any rank.
3. **Lightest first.** Within the preferred set, the two lightest groups (by `weight`) merge first.

This means a ruleset that stamps its module name as the `merge_affinity` on all its groups will see those groups consolidated together under merge pressure, rather than interleaved with unrelated groups — even when an interleaved merge would be marginally cheaper by weight.

Useful weight hints may be language-specific. Good examples include:

- **File count proxy.** Use an aspect to count the number of files in each group. This is cheap and works well in practice.
- **Actual file sizes.** In a repository rule, inspect files of third-party repos and annotate `*_library` targets with the actual byte sizes they contribute to their group.

Groups with large weight are more likely to be left unmerged. They benefit most from being cached as separate entities. Lightweight groups are merged first, as combining them has minimal impact on cache efficiency.

### Testing your implementation

Use `runfiles_group_analysis_test` to verify that your `*_binary` rule produces a valid `RunfilesGroupInfo`. Every binary is analyzed in **two configurations** via a split transition, so a single test target covers these properties:

1. **Well-formedness.** Every entry carries all seven fields, its `kind` is one of `lib.KINDS`, and `executable_group` (if set) names a surviving group. These are checked by `lib.resolve()` itself.
2. **Completeness.** For each runfiles component (files, empty_filenames, symlinks, root_symlinks), the union of all groups must equal the corresponding component of `DefaultInfo.default_runfiles` exactly — no missing entries, no extra entries.
3. **Overlap.** It detects entries that appear in more than one group (per component). The `overlapping_group_behavior` attribute controls whether overlaps produce warnings (default) or hard failures.
4. **Ordering and merging.** `expected_group_names`, `expected_executable_group`, `max_groups` and `expected_group_count` assert the result of the ordering and merge-to-limit steps.
5. **Honoring the global switch.** With `@rules_runfiles_group//runfiles_group:enabled` set to `False`, the binary must provide neither `RunfilesGroupInfo` nor `RunfilesGroupMetadataInfo`. The other checks run in the branch where the flag is `True`. Because the transition pins both branches, the test result does not depend on the flag's value on the command line.

> [!CAUTION]
> This test materializes every depset to compare file sets, making it expensive on large targets. `check_disabled = True` (the default) additionally analyzes the binary and its **entire transitive closure** a second time. Keep one test with `check_disabled = True` to cover the global-switch contract and set it to `False` on the rest. This test is meant for rule authors validating their implementation in internal test suites, not for end users running it on every `*_binary` in a production build.

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

`lib.resolve()` is the whole protocol in one call. It:

1. **Obtains the entries.** If the target has no `RunfilesGroupInfo`, it returns `None` — package `DefaultInfo.default_runfiles` as a single group and skip the rest.
2. **Flattens exactly once** and folds duplicate group names, unioning their runfiles.
3. **Accumulates metadata overrides**, starting with the target's own `RunfilesGroupMetadataInfo` (if any) and then each `aspect_hints` entry that provides one, per-key last-wins. Each override is a patch: fields it does not carry are left alone.
4. **Applies transforms** from every `aspect_hints` entry that provides `RunfilesGroupTransformInfo`, in order, re-validating the result of each.
5. **Orders by `(rank, name)`.**

It returns `struct(groups, by_name, executable_group)`:

- `groups`: the entries, ordered.
- `by_name`: `dict[Label|str, entry]`, keyed by whichever name form the producer used.
- `executable_group`: a group name or `None`, guaranteed to be a key of `by_name`.

Call it **once per consuming target**. It is the only place in the protocol that
flattens a depset, and its result is meant to be used and discarded — do not store it
in a provider, and never call it from an aspect that propagates over `attr_aspects`.

### Using the library

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")

# In an aspect, hints are ctx.rule.attr.aspect_hints. In a rule that cannot see
# them, pass []. The argument is mandatory on purpose: with a default, the correct
# call and the call that silently ignores every user hint look identical.
resolved = lib.resolve(target, aspect_hints = ctx.rule.attr.aspect_hints)

if resolved == None:
    # Mandatory fallback for a binary that does not group its runfiles.
    resolved = lib.resolved([lib.entry(
        name = "my_packager#default",
        runfiles = target[DefaultInfo].default_runfiles,
    )])

# Optional: enforce a group limit before creating layers.
resolved = lib.limit(resolved, max_groups = 5)
if resolved.group_count > 5:
    fail("could not reduce to 5 groups")  # do_not_merge / rank constraints

for entry in resolved.groups:
    # entry.name is a Label (a per-target group) or a string (a named one);
    # lib.name_str(entry) renders either. Also: entry.kind, entry.rank,
    # entry.weight, entry.merge_affinity.
    # entry.runfiles: .files, .symlinks, .root_symlinks, .empty_filenames
    if entry.name == resolved.executable_group:
        # Add the executable, the runfiles symlinks and the repo mapping
        # manifest to this layer.
        ...
    # Create a layer / archive entry / etc., named lib.name_str(entry).
    ...
```

Ordering may not matter for some kinds of packages. In that case, it's advised to still resolve (so that hints are honored) but treat the order of `resolved.groups` as arbitrary.

Key the coarse parts of your API that users configure on `entry.kind` rather than on
individual names. Where you do accept names — an "exclude this group" option, say —
match them against `lib.index_by_name_str(resolved)`, so a user can write either
`"@@//src:lib_a"` — a per-target group's canonical label string — or
`"my_rules#interpreter"` for a named one.

### Respecting `aspect_hints`

Apply an aspect to the `binary` attribute. Inside the aspect, read `ctx.rule.attr.aspect_hints` to access the hint targets and their providers. This is the mechanism through which users customize group behavior without modifying the binary rule.

If your aspect only exists to reach `aspect_hints`, forward the hint targets to your
rule and resolve there — that keeps the O(number of groups) work transient instead of
retained in a provider. [`example/consumer/rules/fake_package.bzl`](example/consumer/rules/fake_package.bzl)
does exactly this.

### Writing a manifest

Do not build a string of runfiles paths during analysis. `json.encode([f.path for f in ...])`
materializes an O(all files) string and `ctx.actions.write` then retains it inside the
action for the whole build. Use `ctx.actions.args()` with `add_all(..., map_each = ...)`
and hand the `Args` object to `ctx.actions.write`: only the (already shared) nested sets
are held, and the file is rendered at execution time.

Render the name with `lib.name_str(entry.name)` first, then pass it as `before_each` —
not `format_each`, because `%` is legal in a label and would corrupt a format template.

---

## Memory

The providers of every configured target stay in Bazel's analysis graph for the life
of the server, so anything a producer retains per target is multiplied by the size of
the build. Two properties keep that bounded:

- **A target's cost does not depend on its closure.** `lib.collect()` references its
  dependencies' entry depsets instead of copying their group sets, so a library at the
  top of a 2000-deep chain retains the same handful of bytes as a leaf. Copying the
  transitive group set into every level instead is quadratic in the number of
  group-producing targets, and it is retained.
- **Group values are existing runfiles objects.** Reuse the object `DefaultInfo`
  already carries where you can; a freshly wrapped one costs a runfiles object plus a
  nested set node per group, retained, and shares nothing.

There is one hard limit to know about: a depset's depth grows by one per nesting level
and Bazel rejects depsets deeper than `--nested_set_depth_limit` (3500 by default).
Pass your own entries to `lib.collect(own = ...)` rather than wrapping its result in a
second depset, so a dependency chain costs one level per target rather than two.

To measure a change, the repository ships a synthetic closure generator and two
scripts:

```console
cd example

# One library's own retained bytes -- what its providers add on top of its deps.
# This number must not grow when the closure grows.
../tools/shallow_bytes.sh //stress:chain250_lib249
../tools/shallow_bytes.sh //stress:chain500_lib499

# Assert the shape rather than an absolute budget (this is the CI guard).
bazel shutdown && ../tools/shallow_bytes.sh //stress:chain250_lib249 > /tmp/s250.txt
bazel shutdown && ../tools/shallow_bytes.sh //stress:chain500_lib499 > /tmp/s500.txt
python3 ../tools/heap_budget.py /tmp/s250.txt /tmp/s500.txt --max-growth 1.3
```

`bazel dump --memory` needs Bazel 8 or newer. For a whole-build number instead, compare
`bazel info used-heap-size-after-gc` after an analysis-only build with the flag off and
on, with a `bazel shutdown` in between — and exclude `runfiles_group_analysis_test`
targets, whose split transition analyzes their closures twice.

---

## Compatibility

### Rulesets producing `RunfilesGroupInfo` (*_binary rules)

| Ruleset | Grouping | Metadata | Weight hints |
|---------|----------|----------|-------------|
| *Your ruleset here* | | | |

### Rulesets consuming `RunfilesGroupInfo` (packaging rules)

| Ruleset | Ordering | Merge-to-limit | `aspect_hints` support |
|---------|----------|----------------|----------------------|
| *Your ruleset here* | | | |

> To add your ruleset to these tables, open a pull request.
