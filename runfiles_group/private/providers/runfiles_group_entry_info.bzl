"""Defines the element type of RunfilesGroupInfo.entries.

One entry describes one runfiles group. It is created by the target that *owns*
the group and then travels up the dependency graph by reference inside a depset;
nothing rewrites it on the way. That is what makes the per-target cost of the
protocol independent of the number of transitive groups.

The provider is deliberately not part of the public API: `lib.entry()` and
`lib.derive()` are the only supported constructors, so every entry in circulation
has been validated.
"""

# Why a schema'd provider rather than struct():
#
#   * struct() is StarlarkInfoNoSchema, which stores its field NAMES in every
#     instance (an Object[2n] table). Seven fields cost 24 + Object[14] = 96
#     bytes. A schema'd instance stores only values -- 24 + Object[7] = 72 bytes
#     -- because the names live once in the provider.
#   * Building a depset hashes every direct element, and flattening a nested one
#     re-hashes. Up to Bazel 9.2.0 StarlarkInfoNoSchema does not override
#     hashCode, so a struct() element falls through to StructImpl.hashCode, which
#     sorts its field names into a fresh list on every call. A schema'd instance
#     hashes its value array directly. Master overrides hashCode on
#     StarlarkInfoNoSchema too, so this half of the argument expires with the next
#     release; the byte difference above does not.
#
# Seven fields is two over a cliff, and stays there: on Bazel master a schema of
# <= 5 fields gets a StarlarkInfoWithSchema subclass holding its values in inline
# Java fields instead of an array -- 40 bytes, against the 72 our seven cost in the
# array-backed SchemaN. Up to 9.2.0 every schema is array-backed and five fields
# cost 64, so the cliff is worth 8 bytes per entry today and 32 once those
# subclasses ship. Reaching it means nesting the five metadata fields behind one
# entry field, which costs the flat entry.rank access packagers read, for a saving
# under a megabyte on a 20k-group build now that entries are shared by reference
# rather than copied per target. Do not add an eighth field without re-reading
# this: the cheap direction is down.
#
# It MUST stay a top-level global: depset element legality goes through
# Starlark.isImmutable -> StarlarkInfoWithSchema.isImmutable, which reports False
# unless the provider is exported. A provider created inside a function is never
# exported and its instances are rejected as depset elements.
#
# There is deliberately no init=: that would allocate a kwargs dict and a
# Starlark frame for every group. Validation lives in lib.entry() instead.

# Closed set of group kinds. "" means unspecified.
#
# `kind` is the protocol's stable, machine-readable selector. A group name is either
# a Label or a ruleset-internal prefixed string, so packager configuration keyed on a
# name breaks the moment a target is renamed; `kind` does not.
#
# It deliberately has no effect on ordering or merging -- that is what `rank` and
# `merge_affinity` are for.
KINDS = [
    "",
    "foundation",  # language runtimes, interpreters, standard libraries
    "third_party",  # dependencies from outside the workspace
    "first_party",  # the workspace's own code and data
    "debug",  # debug symbols, source maps
    "docs",  # documentation, licences, manifests
]

RunfilesGroupEntryInfo = provider(
    doc = "One runfiles group: a name, a runfiles object, and its ordering/merge metadata.",
    fields = {
        "name": """\
Label or str: the group's identity. A Label means a per-target group -- "the
runfiles this one target contributes" -- and needs no prefix, because a Label is
globally unique. A string means a named group that several targets contribute to;
prefix those with something unique to your ruleset. lib.name_str() renders either
form as a string.
""",
        "runfiles": "runfiles: the contents of this group.",
        "kind": "str: one of KINDS. A stable selector for packagers. \"\" means unspecified.",
        "rank": "int: partial ordering key. Lower rank = earlier = more cacheable. Default 0.",
        "do_not_merge": "bool: if True, packagers must not merge this group. Default False.",
        "weight": "int >= 0 or None: merge priority hint. Lighter groups merge first.",
        "merge_affinity": "str: merge grouping hint. \"\" means no affinity.",
    },
)
