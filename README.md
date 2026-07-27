# rules_runfiles_group

A Bazel module that lets `*_binary` rules split their runfiles into named **groups**, and lets
packaging rules consume those groups as partially ordered **layers**. Where a binary provides
`RunfilesGroupInfo`, a packager can produce better artifacts — container images with shared base
layers, archives that keep interpreter, standard library and application code apart — instead of
packing one flat runfiles tree.

```starlark
load("@rules_foo//foo:defs.bzl", "foo_binary")
load("@rules_acme_pkg//pkg:defs.bzl", "pkg_creator")

foo_binary(
    name = "app",
    # Provides RunfilesGroupInfo with groups like "interpreter",
    # "stdlib", "third_party", "app_code" -- or one per dependency.
    ...
)

pkg_creator(
    name = "app_tar",
    binary = ":app",
    # Reads RunfilesGroupInfo, optionally merges groups down to a
    # limit, orders them, and emits one package per group.
)
```

Nothing about this is mandatory on either side. A packager that meets a binary without
`RunfilesGroupInfo` falls back to `DefaultInfo.default_runfiles` as a single group.

**Who should read what:** users → [For users](#for-users). Authors of `*_binary` rules →
[For \*\_binary rule authors](#for-_binary-rule-authors). Authors of packaging rules →
[For packaging rule authors](#for-packaging-rule-authors).

## Installation

Add the module to your `MODULE.bazel`, taking the version from the
[releases page](https://github.com/bazel-contrib/rules_runfiles_group/releases):

```starlark
bazel_dep(name = "rules_runfiles_group", version = "…")
```

Provider emission is **off by default**, so a build pays for it only when something consumes it.
Turn it on where you package:

```
# .bazelrc
common --@rules_runfiles_group//runfiles_group:enabled=true
```

Tested against Bazel 7, 8, 9 and rolling.

## The providers

| Provider | `*_binary` rule | `aspect_hints` | Purpose |
|----------|:-:|:-:|---------|
| `DefaultInfo` | **must** return | — | The executable and runfiles tree. The fallback when `RunfilesGroupInfo` is absent or unsupported. |
| `RunfilesGroupInfo` | may return | — | Splits `DefaultInfo.default_runfiles` into named groups, and names the group that carries the executable. |
| `RunfilesGroupTransformInfo` | — | may add | Transforms the resolved group set (drop a group, remap names, re-rank). |

```starlark
RunfilesGroupInfo(
    entries = <depset of entries, each built with lib.entry()>,
    executable_group = <group name, or None>,
)
```

Each entry carries its own name, contents and metadata, so a target propagates its dependencies'
groups by *referencing* their depsets instead of copying them. That is what keeps a target's cost
independent of how many groups its closure contains — see
[Keeping analysis memory flat](#keeping-analysis-memory-flat).

The full API reference is generated from the docstrings in
[`runfiles_group/lib.bzl`](runfiles_group/lib.bzl) and
[`runfiles_group/providers.bzl`](runfiles_group/providers.bzl). The
[`example/`](example/) directory is a complete end-to-end demo:
[`example/producer/`](example/producer/) implements a `*_binary` rule,
[`example/consumer/`](example/consumer/) a packaging rule, and
[`example/src/`](example/src/) holds user-facing `BUILD` files.

---

## For users

**It just works.** You can package any `*_binary`. If its ruleset doesn't support
`RunfilesGroupInfo`, packaging rules use the flat runfiles from `DefaultInfo`. If it does, you get
smarter layer splitting with no change to your `BUILD` files.

**Customizing groups with `aspect_hints`.** Rulesets may ship hint targets as mixins that adjust
how groups are transformed — for example, one that drops the interpreter group because the base
image already has it:

```starlark
load("@rules_foo//foo:hints.bzl", "skip_interpreter")

skip_interpreter(name = "skip_interpreter")

foo_binary(
    name = "app",
    aspect_hints = [":skip_interpreter"],
    ...
)
```

Hints work by attaching `RunfilesGroupTransformInfo`, which packaging rules pick up through an
aspect; several can be combined on one target. You can also write your own rules that apply an
aspect to a binary to synthesize `RunfilesGroupInfo` — to enforce an organization-wide layering
policy, say. See [the resolution protocol](#the-resolution-protocol).

---

## For `*_binary` rule authors

If splitting runfiles isn't meaningful for your rule — a single statically linked executable, say —
do nothing; packagers fall back to `DefaultInfo`. If it is (interpreter, standard library,
first-party code, third-party deps, debug symbols), return `RunfilesGroupInfo` alongside
`DefaultInfo`.

### Honoring the global on/off switch

The providers cost a little memory on every target that emits them, wasted when no packaging rule
in the build consumes them, so one global flag — shared by every producing ruleset — gates
emission. Honor it with two pieces from `lib`, which are **a pair**:

1. Merge `lib.RULE_ATTRS` into your rule's `attrs`. It adds a private attribute pointing at the
   flag, resolved in the `rules_runfiles_group` repo context, so you never name the label.
2. Gate emission on `lib.is_enabled(ctx)`, returning **before** any grouping work. Without step 1
   this attribute read fails.

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")

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
        return providers  # no ctx.runfiles(), no lib.collect(), no provider
    # ... build entries, then append RunfilesGroupInfo ...
    return providers
```

### Creating entries

`lib.entry()` and `lib.derive()` (a copy with some fields changed) are the only supported entry
constructors; both validate every field.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Label or str | — | The group's identity — see [Naming groups](#naming-groups). |
| `content` | depset of File, or runfiles | — | The group's contents — see [The two content forms](#the-two-content-forms). |
| `kind` | str | `""` | One of `lib.KINDS`. A stable, machine-readable selector for packagers. Does **not** affect ordering or merging. |
| `rank` | int | `0` | Partial ordering key. Lower rank = earlier in the output. Groups at different ranks are never merged. |
| `do_not_merge` | bool | `False` | If True, packagers must not merge this group. |
| `weight` | int >= 0 or None | `None` | Merge priority hint. Lighter groups merge first when reducing group count. `None` lets the packager pick a default. |
| `merge_affinity` | str | `""` | Merge grouping hint: groups sharing an affinity are preferred merge partners. `""` means no affinity. |

A leaf rule with one group of its own:

```starlark
def _asset_bundle_impl(ctx):
    files = depset(ctx.files.srcs)
    providers = [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]
    if not lib.is_enabled(ctx):
        return providers

    # This group is only files, so hand the depset over as-is.
    providers.append(RunfilesGroupInfo(entries = lib.entries([lib.entry(
        name = ctx.label,  # a per-target group: no prefix needed
        content = files,
        kind = "first_party",
        rank = lib.RANK_SHARED_DEPS,
        merge_affinity = "asset_bundle",
    )])))
    return providers
```

### The two content forms

A group's contents are either a **depset of File** or a **runfiles object**, and which one you pass
is a memory decision, not a semantic one.

**A depset of File** means "this group is only files". Most `*_library` groups are: symlinks, root
symlinks and empty filenames are things interpreters and launchers need, not source trees. Hand over
the depset your rule already built and the entry costs nothing beyond the pointer.

**A runfiles object** is the general form, and the only one that can carry symlinks, root symlinks or
empty filenames. Use it for those, and for contents you received from another rule — never inspect
somebody else's runfiles object to decide whether it could have been a depset.

Wrapping a files-only depset in a runfiles object costs **64 retained bytes per group** on Bazel 9
(72 on 7 and 8): a seven-field `Runfiles` plus the nested set node its compile-order builder has to
allocate, because Starlark depsets are stable-ordered. That is per group *created*, retained for the
life of the server, and it buys nothing — the depset already says everything the group knows. In this
repository's own example, moving one library group to the depset form took a library target's
retained providers from 920 to 856 bytes.

Consumers never have to care which form they get:

```starlark
lib.files(entry)          # depset of File -- either form, no ctx needed
lib.runfiles(ctx, entry)  # a runfiles object -- builds one only for the depset form
lib.union(ctx, contents)  # several groups' contents as one, for a producer that aggregates
```

`entry.content` itself is opaque. Read it with those, or pass it straight back to `lib.union()` or
`lib.entry()`; anything else is a bug waiting for the first producer that switches form.

### Propagating entries

**Bottom-up (recommended).** In each `*_library` rule, hand your own entries and your dependencies
to `lib.collect()`. It contributes your entries directly and references your dependencies' depsets,
so it is O(direct deps) and flattens nothing:

```starlark
providers.append(RunfilesGroupInfo(entries = lib.collect(
    ctx,
    deps = [ctx.attr.deps, ctx.attr.exports],
    data = [ctx.attr.data],
    own = [lib.entry(name = ctx.label, content = own_files, kind = "first_party")],
)))
```

`deps` and `data` are each an **iterable of `ctx.attr` values**, so a rule with several Label-typed
attributes collects from all of them in one call — and entry depsets from somewhere other than an
attribute (a toolchain, an aspect's accumulator) go in `transitive = [...]` rather than into a second
depset wrapped around the result.

**Aspect-based.** Apply an aspect to `deps` in the `*_binary` rule and collect entries while
walking the graph. This leaves `*_library` rules untouched but needs an aspect.

> **There is no single best grouping.** Prefer many fine-grained groups and let users coarsen them
> via `aspect_hints`; set `weight` so packagers can merge well. You provide the raw material, users
> shape it.

### Naming groups

A group's name says which of two kinds it is.

**One group per target** — "the runfiles this one target contributes". Name it with a **Label**:
`ctx.label` for your own, `dep.label` for a dependency's. A Label is globally unique, so there is no
prefix to invent and no namespace to coordinate, and it is free — Bazel already interns Labels,
where a string derived from one allocates per target.

**Many targets contributing to one group** — "interpreter", "std", "one per repository". No single
target owns it, so name it with a **string**. Strings share one namespace across every
`RunfilesGroupInfo` merged into a binary, so **prefix them with something unique to your ruleset**:

```starlark
lib.entry(name = ctx.label, content = own_files)              # per-target
lib.entry(name = "my_rules#interpreter", content = ...)       # named
```

Both forms are ordered, folded, merged and looked up identically, and `resolved.by_name` is keyed by
whichever the producer used. Where you need a plain string — an artifact name, an `OutputGroupInfo`
key, a manifest line, an error message — use `lib.name_str()`.

Two entries with the **same** name are legal: `lib.resolve()` folds them into one group, unioning
the contents and taking `min` of `rank`, `or` of `do_not_merge`, `max` of `weight`, and whichever
`kind` and `merge_affinity` is set. That is what collapses a shared data dependency into a single
group no matter how many targets reach it. Contributors to a shared named group need not agree on a
content form; the fold unions across forms.

### Recommended rank values

Ranks form a partial order: lower rank = earlier layer = content that changes least often and is
shared most widely. Negative ranks sort before the default `0`, so foundational content lands in the
earliest, most cacheable layers.

| Constant | Value | Use for |
|----------|-------|---------|
| `lib.RANK_FOUNDATION` | `-1000` | Rarely-changing content shared by many binaries: runtimes, interpreters, standard libraries. |
| `lib.RANK_SHARED_DEPS` | `-100` | Third-party dependencies shared across binaries. |
| `lib.RANK_EXECUTABLE` | `0` | The executable and first-party code. Also the default. |

The anchors are spaced far apart so finer sub-tiers slot in without renumbering — an interpreter at
`RANK_FOUNDATION`, its standard library at `RANK_FOUNDATION + 100`. Put such a derived rank in a
**module-level constant**: Bazel only caches small integers, so computing one per target allocates
and retains a boxed integer per target. Within a rank, the packager may order and merge freely.

### `kind`, `merge_affinity` and `weight`

`kind` is the protocol's stable selector. Names are Labels or ruleset-internal strings, so packager
configuration keyed on a name breaks the moment a target is renamed; `kind` doesn't, which makes it
the right key for a packager's "include these / exclude those / put these in that layer" options.
`lib.KINDS` is a closed set — `""`, `"foundation"`, `"third_party"`, `"first_party"`, `"debug"`,
`"docs"` — and deliberately has **no** effect on ordering or merging.

`merge_affinity` steers *which* groups merge when a packager must reduce the group count.
**Recommendation: use your module name, and stamp it on every group your ruleset produces**, so your
groups consolidate together under merge pressure instead of interleaving with unrelated ones.
Affinities are a shared namespace, so modules may deliberately reuse a value to opt into the same
grouping — `rules_java` could cover every JVM-shaped group, including those from
`rules_jvm_external` or Kotlin rules.

Weights are language-specific; two that work well are a file count per group (cheap, computed in an
aspect) and real byte sizes recorded by a repository rule. Heavy groups are the ones left unmerged,
which is what you want — they benefit most from separate caching.

### Marking the group that carries the executable

`RunfilesGroupInfo` only covers what is inside `DefaultInfo.default_runfiles`. The remaining pieces
of an executable — the runfiles symlinks, the repo mapping manifest — still need a home. Point
`executable_group` at the group where they belong:

```starlark
RunfilesGroupInfo(
    entries = lib.entries(entries),
    executable_group = "my_rules#app_code",  # or a Label, for a per-target group
)
```

`lib.resolve()` fails if it names no surviving group, so it cannot go stale after a rename or a
merge; `None` leaves the choice to the packager. It is only meaningful on the **top-level** target —
`lib.collect()` never propagates a dependency's, so a binary used as another binary's `data` can't
claim the outer entrypoint.

### Handling `deps` and `data`

Both are mandatory keywords on `lib.collect()`, because `data` is the classic footgun here — pass
`data = []` explicitly if your rule has none. Each is an iterable of `ctx.attr` values, and every
Label-typed attribute kind is accepted, whatever shape `ctx.attr` gives it:

| Attribute kind | `ctx.attr` value |
|----------------|------------------|
| `attr.label` | a `Target` |
| `attr.label_list` | a list of `Target` |
| `attr.label_keyed_string_dict` | `Target` → string |
| `attr.string_keyed_label_dict` | string → `Target` |
| `attr.label_list_dict` (Bazel 9+) | string → list of `Target` |

Every `Target` found contributes; the string side of a keyed dict is skipped. A rule with a single
`label_list` can still pass `deps = ctx.attr.deps` unwrapped, since a list of `Target` is itself an
iterable of legal elements.
[`example/producer/rules/starlark_app.bzl`](example/producer/rules/starlark_app.bzl) is a rule that
collects from one attribute of every kind, with
[`example/src/app/`](example/src/app/) checking that each one's libraries land in a group.

**`deps`** are usually your own `*_library` targets, which provide `RunfilesGroupInfo`; their entry
depsets are referenced directly. A `deps` target *without* `RunfilesGroupInfo` contributes nothing —
there is no synthesized fallback. These are your ruleset's own targets, so one that doesn't speak the
protocol is a bug, and synthesizing a group would both hide it and claim that target's whole
`DefaultInfo`, which for a `*_library` is its entire closure's runfiles and overlaps the groups of
everything else that closure reaches. So a dependency that has no `RunfilesGroupInfo` *and*
contributes to your `default_runfiles` belongs in `data`, or a packager will find no group holding
its files.

**`data`** can be anything. For targets without `RunfilesGroupInfo`, `lib.collect()` synthesizes a
per-target entry named by the dep's `Label`, covering its `DefaultInfo.files` and
`default_runfiles`, with no `kind` and no `merge_affinity`. Because the name *is* the label, two
paths to the same data dep produce the same group, which `lib.resolve()` folds back into one. That
synthesized entry always uses the runfiles form: deciding otherwise would mean inspecting a foreign
runfiles object to see whether it holds anything besides files, and reading its `empty_filenames` is
O(all files) for a dep that carries an empty-files supplier.

One thing a `data` dep must not do, because `lib.collect()` cannot work around it: rely on its
executable being inside its own `default_runfiles`. Bazel merges the executable in for Starlark
rules, but a native one — a single-output `genrule` — publishes empty `default_runfiles` next to a
perfectly good `files_to_run.executable`. If your rule puts a dependency's executable in a group, put
the *same* runfiles object into `default_runfiles` rather than assuming it did.

A dep publishing `DefaultInfo(files = depset(..., order = "topological"))` or `"preorder"` is fine.
Those orders are illegal for `ctx.runfiles(transitive_files = ...)`, and Starlark cannot read a
depset's order back to check — but it can neutralize one, so `lib` rewraps every depset it is handed
in default order. The rewrap returns the caller's own object when it already was default-ordered, so
the common path allocates nothing.

### Testing your implementation

`runfiles_group_analysis_test` analyzes each binary in **two configurations** via a split
transition, so one target covers:

1. **Well-formedness** — every entry carries all seven fields, `content` is one of the two legal
   forms, `kind` is one of `lib.KINDS`, and `executable_group` (if set) names a surviving group.
   Checked by `lib.resolve()` itself.
2. **Completeness** — per runfiles component (`files`, `empty_filenames`, `symlinks`,
   `root_symlinks`), the union of all groups must equal `DefaultInfo.default_runfiles` exactly. A
   files-only group contributes its files and nothing to the other three, so a rule whose runfiles
   carry symlinks cannot cover them with a depset-form group.
3. **Overlap** — entries appearing in more than one group.
   `overlapping_group_behavior` picks `"warn"` (default), `"error"` or `"ignore"`.
4. **Ordering and merging** — asserted with `expected_group_names`, `expected_executable_group`,
   `max_groups` and `expected_group_count`.
5. **The global switch** — with the flag `False`, the binary must provide no `RunfilesGroupInfo`.
   Both branches are pinned by the transition, so the result doesn't depend on the flag's value on
   the command line.

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [":my_binary", ":my_other_binary"],
    overlapping_group_behavior = "error",
)
```

> [!CAUTION]
> The test materializes every depset to compare file sets, so it is expensive on large targets, and
> `check_disabled = True` (the default) analyzes the binary's **entire transitive closure** a second
> time. Keep one test with `check_disabled = True` for the global-switch contract and set it to
> `False` on the rest. This is a tool for rule authors' own test suites, not for every `*_binary` in
> a production build.

---

## For packaging rule authors

### The resolution protocol

`lib.resolve()` is the whole protocol in one call. It:

1. **Obtains the entries.** Returns `None` if the target carries no groups — package
   `DefaultInfo.default_runfiles` as a single group and skip the rest.
2. **Flattens exactly once** and folds duplicate names, unioning their contents.
3. **Applies transforms** from every `aspect_hints` entry providing
   `RunfilesGroupTransformInfo`, in order, re-validating each result.
4. **Orders by `(rank, name)`.**

It returns `struct(groups, by_name, executable_group)`, where `by_name` is
`dict[Label|str, entry]` keyed by whichever name form the producer used, and `executable_group` is
guaranteed to be one of its keys, or `None`.

Call it **once per consuming target**. It is the only place in the protocol that flattens a depset;
its result is meant to be used and discarded — never store it in a provider, and never call it from
an aspect that propagates over `attr_aspects`.

```starlark
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")

# In an aspect, hints are ctx.rule.attr.aspect_hints; in a rule that cannot see
# them, pass []. The argument is mandatory on purpose: with a default, the correct
# call and the one that silently ignores every user hint look identical.
resolved = lib.resolve(ctx, target, aspect_hints = ctx.rule.attr.aspect_hints)

if resolved == None:
    # Mandatory fallback for a binary that does not group its runfiles.
    resolved = lib.resolved([lib.entry(
        name = "my_packager#default",
        content = target[DefaultInfo].default_runfiles,
    )])

# Optional: enforce a group limit before creating layers.
resolved = lib.limit(ctx, resolved, max_groups = 5)
if resolved.group_count > 5:
    fail("could not reduce to 5 groups")  # do_not_merge / rank constraints

for entry in resolved.groups:
    # entry.name is a Label (per-target) or a string (named); lib.name_str()
    # renders either. Also: entry.kind, entry.rank, entry.weight and
    # entry.merge_affinity.
    #
    # Contents go through lib, never through entry.content: lib.files(entry) for
    # the paths, lib.runfiles(ctx, entry) when you have to place a complete
    # runfiles tree. See "The two content forms".
    for file in lib.files(entry).to_list():
        ...
    if entry.name == resolved.executable_group:
        # Add the executable, the runfiles symlinks and the repo mapping manifest here.
        ...
```

Key the coarse, user-configurable parts of your API on `entry.kind` rather than on individual
names. Where you do accept names — an "exclude this group" option — match them against
`lib.index_by_name_str(resolved)`, so a user can write either `"@@//src:lib_a"` (a per-target
group's canonical label string) or `"my_rules#interpreter"`.

If ordering is irrelevant to your format, still resolve — that is what honors user hints — and
treat the order of `resolved.groups` as arbitrary.

### Group count limits

`lib.limit()` merges groups until at most `max_groups` remain, for formats with a hard cap such as
container image layers. It picks each merge in this order:

1. **Same rank only.** Groups at different ranks never merge.
2. **Prefer the same `merge_affinity`** (`""` is the shared "no affinity" bucket). It only merges
   across affinities when no same-affinity pair remains at any rank.
3. **Lightest first**, by `weight`.

`do_not_merge` groups are never touched, so `max_groups` may be unreachable — the caller **must**
check `group_count`. The optional `merged_group_name` callback receives the two names in their
original form and may return either; a merged group is rarely still one target's, so a string built
with `lib.name_str()` is the usual answer.

### Respecting `aspect_hints`

`aspect_hints` is only reachable from an aspect, so apply one to your `binary` attribute and read
`ctx.rule.attr.aspect_hints`. If the aspect exists for no other reason, have it forward the hint
targets and resolve in the rule — that keeps the O(groups) work transient instead of retained in a
provider. [`example/consumer/rules/fake_package.bzl`](example/consumer/rules/fake_package.bzl) does
exactly this.

### Writing a manifest

Don't build a string of runfiles paths during analysis: `json.encode([f.path for f in ...])`
materializes an O(all files) string and `ctx.actions.write` then retains it inside the action for
the whole build. Pass a `ctx.actions.args()` with `add_all(..., map_each = ...)` to
`ctx.actions.write` instead — only the already-shared nested sets are held, and the file is
rendered at execution time. Render the group name with `lib.name_str()` and pass it as
`before_each`, not `format_each`: `%` is legal in a label and would corrupt a format template.

---

## Keeping analysis memory flat

Every configured target's providers stay in Bazel's analysis graph for the life of the server, so
whatever a producer retains per target is multiplied by the size of the build. Five rules keep that
bounded:

- **A target's cost must not depend on its closure.** `lib.collect()` references its dependencies'
  entry depsets instead of copying their group sets, so a library atop a 2000-deep chain retains as
  much as a leaf. Copying the transitive group set into every level is quadratic — and retained.
- **Never call `.to_list()` in a `*_library` rule** — not on runfiles, not on
  `RunfilesGroupInfo.entries`. `lib.collect()` flattens nothing; `lib.resolve()` does, and it
  belongs in the packaging rule (or, at most once per target, in a `*_binary` that genuinely must
  re-shape its dependencies' groups).
- **Give a files-only group its depset, not a runfiles object.** See
  [The two content forms](#the-two-content-forms): the wrapper is 64 retained bytes per group that
  say nothing the depset does not. Consumers cope through `lib.files()` and `lib.runfiles()`.
- **Reuse existing runfiles objects** where you do need the runfiles form. A freshly wrapped one
  costs a runfiles object plus a nested set node per group, retained, and shares nothing. For the same
  reason, never merge runfiles in a loop: accumulate a list and call `runfiles.merge_all()` once, or
  hand the parts to `lib.union()`.
- **Pass your own entries to `lib.collect(own = ...)`** rather than wrapping its result in a second
  depset, so a dependency chain costs one level of depset depth per target instead of two. Bazel
  rejects depsets deeper than `--nested_set_depth_limit` (3500 by default).

To measure a change, the repository ships a synthetic closure generator and two scripts:

```console
cd example

# One library's own retained bytes -- what its providers add on top of its deps.
# This number must not grow when the closure grows (the shape the CI guard asserts).
# A fresh server per measurement: several Bazel interners are process-global.
bazel shutdown && ../tools/shallow_bytes.sh //stress:chain250_lib249 > /tmp/s250.txt
bazel shutdown && ../tools/shallow_bytes.sh //stress:chain500_lib499 > /tmp/s500.txt
python3 ../tools/heap_budget.py /tmp/s250.txt /tmp/s500.txt --max-growth 1.3
```

`bazel dump --memory` needs Bazel 8 or newer. For a whole-build number, compare
`bazel info used-heap-size-after-gc` after an analysis-only build with the flag off and on, with a
`bazel shutdown` in between — and exclude `runfiles_group_analysis_test` targets, whose split
transition analyzes their closures twice.

---

## Compatibility

### Rulesets producing `RunfilesGroupInfo` (`*_binary` rules)

| Ruleset | Grouping | Metadata | Weight hints |
|---------|----------|----------|-------------|
| *Your ruleset here* | | | |

### Rulesets consuming `RunfilesGroupInfo` (packaging rules)

| Ruleset | Ordering | Merge-to-limit | `aspect_hints` support |
|---------|----------|----------------|----------------------|
| *Your ruleset here* | | | |

> To add your ruleset to these tables, open a pull request.
