"""Provider for Starlark source files."""

StarlarkInfo = provider(
    doc = "A depset of Starlark source files needed at runtime.",
    fields = {
        "sources": "depset of File objects containing Starlark source files.",
        "loadpath": "string load path prefix for this library (e.g. '//src' or '@myrepo//src').",
        "repos": "depset of (friendly_name, canonical_name) tuples mapping repository names.",
    },
)
