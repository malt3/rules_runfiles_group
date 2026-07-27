"""Defines provider for grouping runfiles into different subcategories.

This is essentially a special-purpose version of OutputGroupInfo.
If present, it can be used instead of DefaultInfo.default_runfiles."""

_DOC = """\
Runfiles of a target, split into named groups.

Fields:

- `entries`: a depset of group entries, each built with `runfiles_groups.entry()`.
  Every entry carries its own name, contents and ordering/merge metadata, so a
  target propagates its dependencies' groups by referencing their depsets rather
  than by copying them. The per-target cost is therefore independent of how many
  groups the transitive closure contains.

  A group's name is either a **Label**, meaning a per-target group ("the runfiles
  this one target contributes"), or a **string**, meaning a named group that
  several targets contribute to. See `runfiles_groups.entry()`, and
  `runfiles_groups.name_str()` for rendering either form as a string.

  A group's contents are either a **runfiles object** or, for a group that is only
  files, a **depset of File**. Consumers read both through
  `runfiles_groups.files(entry)` and `runfiles_groups.runfiles(ctx, entry)` and must
  not touch `entry.content` directly, other than to pass it back to
  `runfiles_groups.union()` or `runfiles_groups.entry()`.

  The depset order MUST be `"default"` (stable): it is the only order that can be
  merged with every other order, which a producer needs in order to combine entry
  depsets coming from foreign rulesets. Starlark cannot read a depset's order
  back, so build the depset with `runfiles_groups.entries()` or
  `runfiles_groups.collect()`, which do it correctly. Traversal order is never
  observable: `runfiles_groups.resolve()` sorts by `(rank, name)`.

  Group names MAY repeat across the depset -- two targets can each synthesize an
  entry for the same shared data dependency. `runfiles_groups.resolve()` folds
  duplicates by name, unioning their contents.

- `executable_group`: the *name* of the group that should receive the executable,
  the runfiles symlinks, the repo mapping manifest and the other supporting files
  of the entrypoint, or None to let the packager decide. Either name form.

  A name rather than a reference to an entry, because a name survives renaming,
  merging and hint transforms, can be validated (`runfiles_groups.resolve()` fails
  if it names no surviving group), and is greppable. Entry references would compare
  by value, so a stale one would silently match nothing -- or two entries at once.

  Only meaningful on the top-level target. `runfiles_groups.collect()` never
  propagates a dependency's, so nothing has to be stripped.

Unioning the contents of every entry must yield the same runfiles as
DefaultInfo.default_runfiles. A group whose contents are a depset of File
contributes exactly those files and no symlinks, root symlinks or empty filenames,
so a rule whose runfiles carry any of those cannot express them in that form.

This provider functions similarly to OutputGroupInfo, but its presence in the
output of a rule indicates that it can be used instead of
DefaultInfo.default_runfiles.
"""

_DEPSET_TYPE = type(depset())

def _make_runfilesgroupinfo_init(*, entries, executable_group = None):
    if type(entries) != _DEPSET_TYPE:
        fail("RunfilesGroupInfo: entries must be a depset of entries built with runfiles_groups.entry(), got ", type(entries))
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
        "entries": "depset of group entries, order = \"default\". Build it with runfiles_groups.entries() or runfiles_groups.collect().",
        "executable_group": "Label, str or None: name of the group that carries the executable and its supporting files.",
    },
)
