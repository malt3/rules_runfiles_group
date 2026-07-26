"""Consumer rule that resolves runfiles groups from a binary via an aspect."""

load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")

# The aspect exists for exactly one reason: aspect_hints is only reachable from an
# aspect (ctx.rule.attr.aspect_hints), not from a rule. So the aspect forwards the
# hint targets -- O(number of hints) references, which Skyframe retains anyway --
# and the rule does all the O(groups) work transiently. Storing lib.resolve()'s
# output here instead would retain a list plus one entry per group on every
# packaging target for the life of the build.
_FakePackageHintsInfo = provider(
    doc = "The binary's aspect_hints, forwarded so the packaging rule can resolve groups.",
    fields = {"aspect_hints": "list of Target: the binary's aspect_hints."},
)

def _fake_package_aspect_impl(_target, ctx):
    return [_FakePackageHintsInfo(aspect_hints = ctx.rule.attr.aspect_hints)]

_fake_package_aspect = aspect(
    implementation = _fake_package_aspect_impl,
)

def _short_path(file):
    return file.short_path

def _fake_package_impl(ctx):
    binary = ctx.attr.binary
    hints = binary[_FakePackageHintsInfo].aspect_hints

    # One call does the whole resolution protocol: flatten the entry depset once,
    # fold duplicate group names, apply the metadata overrides from the target and
    # from the hints, run the hint transforms, order by (rank, name). The ctx is
    # needed only if folding has to union a files-only group with a runfiles-form
    # one.
    resolved = lib.resolve(ctx, binary, aspect_hints = hints)

    if resolved == None:
        # Mandatory fallback: a binary that does not group its runfiles is
        # packaged as a single group.
        resolved = lib.resolved([lib.entry(
            name = "fake_package#default",
            content = binary[DefaultInfo].default_runfiles,
        )])

    # Write the manifest from an Args object rather than a string built during
    # analysis: json.encode(...) over every path materialized an O(all files)
    # string and ctx.actions.write stored it inside the action, retained for the
    # whole build. With Args, only the (already shared) nested sets are held and
    # the file is rendered at execution time.
    #
    # lib.name_str renders either name form: a per-target group's Label or a named
    # group's string. before_each rather than format_each, because group names are
    # arbitrary strings and '%' is legal in a label, which would corrupt a format
    # template.
    # lib.files() reads either content form, so this packager never has to know
    # whether a producer handed over a runfiles object or a bare depset. A real
    # packager that has to place a complete runfiles tree -- symlinks, empty files
    # and all -- would call lib.runfiles(ctx, entry) instead, and would still not
    # care which form it started from.
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    for entry in resolved.groups:
        args.add_all(
            lib.files(entry),
            before_each = "{}\t{}".format(entry.kind, lib.name_str(entry.name)),
            map_each = _short_path,
            expand_directories = False,
        )

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, args)

    # Output group names have to be strings, so this is one of the places a
    # packager canonicalizes. A real packager would also put the launcher, the
    # runfiles symlinks and the repo mapping manifest into resolved.executable_group.
    output_groups = {}
    for entry in resolved.groups:
        output_groups[lib.name_str(entry.name)] = lib.files(entry)

    return [
        DefaultInfo(files = depset([manifest])),
        OutputGroupInfo(**output_groups),
    ]

fake_package = rule(
    implementation = _fake_package_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            aspects = [_fake_package_aspect],
            doc = "A binary target. RunfilesGroupInfo is used when present.",
        ),
    },
)
