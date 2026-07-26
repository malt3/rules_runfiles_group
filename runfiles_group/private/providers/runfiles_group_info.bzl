"""Defines provider for grouping runfiles into different subcategories.

This is essentially a special-purpose version of OutputGroupInfo.
If present, it can be used instead of DefaultInfo.default_runfiles."""

_DOC = """\
Runfiles of a target, split into named groups.

Fields:

- `entries`: a depset of group entries, each built with `lib.entry()`. Every
  entry carries its own name, runfiles and ordering/merge metadata, so a target
  propagates its dependencies' groups by referencing their depsets rather than by
  copying them. The per-target cost is therefore independent of how many groups
  the transitive closure contains.

  A group's name is either a **Label**, meaning a per-target group ("the runfiles
  this one target contributes"), or a **string**, meaning a named group that
  several targets contribute to. See `lib.entry()`, and `lib.name_str()` for
  rendering either form as a string.

  The depset order MUST be `"default"` (stable): it is the only order that can be
  merged with every other order, which a producer needs in order to combine entry
  depsets coming from foreign rulesets. Starlark cannot read a depset's order
  back, so build the depset with `lib.entries()` or `lib.collect()`, which do it
  correctly. Traversal order is never observable: `lib.resolve()` sorts by
  `(rank, name)`.

  Group names MAY repeat across the depset -- two targets can each synthesize an
  entry for the same shared data dependency. `lib.resolve()` folds duplicates by
  name, unioning their runfiles.

- `executable_group`: the *name* of the group that should receive the executable,
  the runfiles symlinks, the repo mapping manifest and the other supporting files
  of the entrypoint, or None to let the packager decide. Either name form.

  A name rather than a reference to an entry, because a name survives renaming,
  merging and hint transforms, can be validated (`lib.resolve()` fails if it names
  no surviving group), and is greppable. Entry references would compare by value,
  so a stale one would silently match nothing -- or two entries at once.

  Only meaningful on the top-level target. `lib.collect()` never propagates a
  dependency's, so nothing has to be stripped.

Merging the `runfiles` of every entry must yield the same runfiles as
DefaultInfo.default_runfiles.

This provider functions similarly to OutputGroupInfo, but its presence in the
output of a rule indicates that it can be used instead of
DefaultInfo.default_runfiles.
"""

def _make_runfilesgroupinfo_init(*, entries, executable_group = None):
    if type(entries) != "depset":
        fail("RunfilesGroupInfo: entries must be a depset of entries built with lib.entry(), got ", type(entries))
    if executable_group != None:
        if type(executable_group) == "string":
            if not executable_group:
                fail("RunfilesGroupInfo: executable_group must not be an empty string")
        elif type(executable_group) != "Label":
            fail("RunfilesGroupInfo: executable_group must be a group name (Label or string) or None, got ", type(executable_group))
    return {"entries": entries, "executable_group": executable_group}

# `entries` is a schema'd field on purpose: Bazel unwraps a depset stored in a
# schema'd provider field down to its raw nested set, eliding the depset wrapper
# per instance, and rewraps it on read. Schemaless (dynamic-field) providers do
# not get that.
RunfilesGroupInfo, _ = provider(
    doc = _DOC,
    init = _make_runfilesgroupinfo_init,
    fields = {
        "entries": "depset of group entries, order = \"default\". Build it with lib.entries() or lib.collect().",
        "executable_group": "Label, str or None: name of the group that carries the executable and its supporting files.",
    },
)
