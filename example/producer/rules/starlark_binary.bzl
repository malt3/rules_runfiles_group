"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:callback.bzl", "RunfilesGroupCallbackInfo")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "runfiles_groups")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//producer/providers:providers.bzl", "StarlarkBinaryInfo", "StarlarkInfo")

_GROUP_PREFIX = "starlark_runfiles_group#"

# Merge affinity stamped on every group this ruleset produces. See the
# matching comment in starlark_library.bzl.
_AFFINITY = "starlark"

# Module-level so the boxed int is allocated once at load time. StarlarkInt only
# caches [-128, 99871], so evaluating `runfiles_groups.RANK_FOUNDATION + 100` in
# the rule implementation would allocate a fresh 16-byte object per target and
# retain it inside the metadata struct.
_RANK_STD = runfiles_groups.RANK_FOUNDATION + 100

# Fixed group names, built once at load time rather than per target. A group name
# is retained inside its entry, so concatenating a constant in the rule
# implementation retains one copy of the same string per binary.
_GROUP_INTERPRETER = _GROUP_PREFIX + "interpreter"
_GROUP_STD = _GROUP_PREFIX + "std"
_GROUP_ENTRYPOINT = _GROUP_PREFIX + "entrypoint"

def _canonical_repo_name(ctx):
    return ctx.label.repo_name or "_main"

def _starlark_binary_impl(ctx):
    interpreter_info = ctx.attr.interpreter[DefaultInfo]
    interpreter_exe = interpreter_info.files_to_run.executable
    entrypoint = ctx.file.src
    current_repo = _canonical_repo_name(ctx)

    # Collect repos from all deps + self + standard library
    transitive_repos = [dep[StarlarkInfo].repos for dep in ctx.attr.deps]
    stdlib = ctx.attr._standard_library
    all_repos = depset(
        [
            (ctx.attr.repository, current_repo),
            ("std", stdlib.label.repo_name or "_main"),
        ],
        transitive = transitive_repos,
    )

    # Generate loadmap file
    loadmap = ctx.actions.declare_file(ctx.label.name + ".loadmap")
    output_args = ctx.actions.args()
    output_args.add("--output", loadmap)
    repo_args = ctx.actions.args()
    repo_args.set_param_file_format("multiline")
    repo_args.use_param_file("--repos=%s", use_always = True)
    repo_args.add_all(all_repos, map_each = _format_repo)

    ctx.actions.run(
        executable = ctx.executable._loadmap_generator,
        arguments = [output_args, repo_args],
        outputs = [loadmap],
        mnemonic = "StarlarkLoadmap",
        progress_message = "Generating loadmap for %{label}",
    )

    # Write properties file
    properties = ctx.actions.declare_file(ctx.label.name + ".properties.json")
    expanded_props = {}
    for k, v in ctx.attr.properties.items():
        expanded_props[k] = ctx.expand_location(v, ctx.attr.data)
    ctx.actions.write(properties, json.encode(expanded_props))

    # Build launcher stub: interpreter --repo <repo> --loadmap <loadmap> --properties <props> <entrypoint_label>
    if ctx.attr.repository:
        entry_label = "@" + ctx.attr.repository + "//" + entrypoint.owner.package + ":" + entrypoint.owner.name
    else:
        entry_label = "//" + entrypoint.owner.package + ":" + entrypoint.owner.name

    embedded_args, transformed_args = launcher.args_from_entrypoint(interpreter_exe)
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--repo",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = current_repo,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--loadmap",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_runfile(
        file = loadmap,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = "--properties",
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_runfile(
        file = properties,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )
    embedded_args, transformed_args = launcher.append_embedded_arg(
        arg = entry_label,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
    )

    output = ctx.actions.declare_file(ctx.label.name)
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = output,
        template_file = ctx.file._launcher,
    )

    # Runfiles: interpreter + entrypoint + loadmap + stdlib + data + all deps.
    #
    # The entrypoint bundle is only files, so the "entrypoint" group carries this
    # depset itself and default_runfiles is built from the same depset: the two
    # cannot drift apart, and no runfiles object is retained on the group's behalf.
    # The executable is already part of default_runfiles for an executable Starlark
    # rule, so naming it here changes nothing about the contents.
    #
    # The loadmap and the properties file are declared here and appear in no
    # attribute, so the describe function -- which runs in an aspect and sees only
    # providers and ctx.rule.attr -- cannot rebuild this depset. It is published on
    # StarlarkBinaryInfo below.
    entrypoint_files = depset([output, entrypoint, loadmap, properties])
    entrypoint_runfiles = ctx.runfiles(transitive_files = entrypoint_files)

    # The interpreter group's value and the interpreter's contribution to
    # default_runfiles must be the SAME object, or the group can end up holding
    # files the binary's own runfiles never got. That is also why this one is
    # published rather than rebuilt in the describe function from
    # ctx.rule.attr.interpreter: an equal-but-separate object is exactly the thing
    # that drifts. Do not assume a dependency's executable is already inside its
    # default_runfiles: Bazel merges it in for Starlark rules, but a native one (a
    # single-output genrule, say) publishes an empty default_runfiles next to a
    # perfectly good files_to_run.executable.
    interpreter_runfiles = ctx.runfiles(files = [interpreter_exe]).merge(interpreter_info.default_runfiles)
    stdlib_info = stdlib[DefaultInfo]

    # One merge_all rather than a fold: see the comment in starlark_library.bzl.
    to_merge = [
        interpreter_runfiles,
        stdlib_info.default_runfiles,
    ]
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps])
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    runfiles = entrypoint_runfiles.merge_all(to_merge)

    return [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
        StarlarkBinaryInfo(
            entrypoint_files = entrypoint_files,
            interpreter_runfiles = interpreter_runfiles,
        ),
    ]

def _starlark_binary_groups(target, ctx, _payload):
    """Describes a starlark_binary's runfiles as groups.

    Called by runfiles_group_aspect, so `ctx` is the aspect's. Everything this
    needs is either on the target (StarlarkBinaryInfo, for what the rule computed)
    or reachable through ctx.rule.attr.

    Args:
        target: The starlark_binary being described.
        ctx: The aspect context.
        _payload: Unused; this callback carries none.

    Returns:
        RunfilesGroupInfo, or None if this binary opted out of grouping.
    """
    attrs = ctx.rule.attr
    if attrs.runfiles_grouping == "disabled":
        # Not describable, which is not the same as "describable and empty": the
        # packager falls back to DefaultInfo.default_runfiles as a single group.
        return None

    binary_info = target[StarlarkBinaryInfo]
    entrypoint_files = binary_info.entrypoint_files
    stdlib_runfiles = attrs._standard_library[DefaultInfo].default_runfiles
    current_repo = target.label.repo_name or "_main"

    # The canonical repository name, because that is what a group's Label
    # reports. attrs.repository is this ruleset's own friendly alias and only
    # exists for the Starlark load path.
    own_repo = target.label.repo_name

    # Both grouping modes re-shape the collected groups, so this binary is a
    # "materializing" target: it flattens the dependencies' entry depset once.
    # A *_library must never do this -- its describe function only ever calls
    # runfiles_groups.collect(). Doing it here is O(closure) once per binary, not
    # once per visited target, because only binaries reach this branch.
    collected = runfiles_groups.resolve(
        ctx,
        runfiles_groups.collect(ctx, deps = [attrs.deps], data = [attrs.data]),
        aspect_hints = [],
    )

    entries = [
        # Special group: interpreter. Keeps the runfiles form because it merges
        # a dependency's default_runfiles, which may carry symlinks.
        runfiles_groups.entry(
            name = _GROUP_INTERPRETER,
            content = binary_info.interpreter_runfiles,
            kind = "foundation",
            rank = runfiles_groups.RANK_FOUNDATION,
            do_not_merge = True,
            merge_affinity = _AFFINITY,
        ),
        # Special group: std. Likewise -- these contents came from another rule.
        runfiles_groups.entry(
            name = _GROUP_STD,
            content = stdlib_runfiles,
            kind = "foundation",
            rank = _RANK_STD,
            merge_affinity = _AFFINITY,
        ),
    ]

    if attrs.runfiles_grouping == "by_target":
        # One group per transitive target, re-ranked relative to this binary.
        # runfiles_groups.derive carries weight, merge_affinity and kind
        # through, so re-ranking cannot silently reset them -- and it carries the
        # contents through in whichever form the producer chose, so re-ranking a
        # dependency's files-only group does not materialize anything.
        executable_group = _GROUP_ENTRYPOINT
        entries.append(runfiles_groups.entry(
            name = executable_group,
            content = entrypoint_files,
            kind = "first_party",
            rank = runfiles_groups.RANK_EXECUTABLE,
            merge_affinity = _AFFINITY,
        ))
        if collected != None:
            for entry in collected.groups:
                entries.append(runfiles_groups.derive(entry, rank = _dep_rank(entry.name, own_repo)))

    else:
        # One group per repository: a *named* group, because many targets
        # contribute to each one. Members' weights are summed, and their
        # affinity and kind adopted, so the aggregate still carries usable
        # merge hints.
        #
        # Reading the repository off a per-target group is just
        # entry.name.repo_name -- no string parsing, and no dependence on how
        # another ruleset happens to spell its names.
        #
        # entry.content is opaque here: it goes straight to
        # runfiles_groups.union(), which unions the two content forms and stays
        # in the depset form when every part is one. A repository whose groups are
        # all files-only therefore aggregates without building a runfiles object at
        # all.
        repo_contents = {own_repo: [entrypoint_files]}
        repo_weights = {}
        repo_affinities = {}
        repo_kinds = {}
        if collected != None:
            for entry in collected.groups:
                repo = _entry_repo(entry.name)
                repo_contents.setdefault(repo, []).append(entry.content)
                if entry.weight != None:
                    repo_weights[repo] = repo_weights.get(repo, 0) + entry.weight

                # Data deps without RunfilesGroupInfo contribute the empty
                # affinity and kind, which never override a member's.
                if entry.merge_affinity:
                    repo_affinities[repo] = entry.merge_affinity
                if entry.kind:
                    repo_kinds[repo] = entry.kind

        executable_group = _GROUP_PREFIX + current_repo
        for repo, parts in repo_contents.items():
            group_name = _GROUP_PREFIX + (repo or "_main")
            merged = runfiles_groups.union(ctx, parts)
            if repo == own_repo:
                entries.append(runfiles_groups.entry(
                    name = group_name,
                    content = merged,
                    kind = "first_party",
                    rank = runfiles_groups.RANK_EXECUTABLE,
                    weight = repo_weights.get(repo, None),
                    merge_affinity = _AFFINITY,
                ))
            else:
                entries.append(runfiles_groups.entry(
                    name = group_name,
                    content = merged,
                    kind = repo_kinds.get(repo, ""),
                    rank = runfiles_groups.RANK_SHARED_DEPS,
                    weight = repo_weights.get(repo, None),
                    merge_affinity = repo_affinities.get(repo, ""),
                ))

    return RunfilesGroupInfo(
        entries = runfiles_groups.entries(entries),
        executable_group = executable_group,
    )

def _starlark_binary_callback_impl(_ctx):
    return [RunfilesGroupCallbackInfo(describe = _starlark_binary_groups)]

starlark_binary_runfiles_group_callback = rule(
    implementation = _starlark_binary_callback_impl,
    doc = "Publishes how a starlark_binary's runfiles are grouped.",
    provides = [RunfilesGroupCallbackInfo],
)

def _entry_repo(name):
    """Canonical repository name a group belongs to, or "" for the main repository.

    A per-target group knows its repository exactly: it is the Label's. A *named*
    group belongs to no single repository -- it is the point of a named group that
    several targets contribute to it -- so it lands in the main-repository bucket,
    which is where this ruleset's own named groups belong anyway.
    """
    if type(name) == "Label":
        return name.repo_name
    return ""

def _dep_rank(name, own_repo):
    """Rank for a collected dep/data group in by_target grouping.

    First-party (own-repo) groups sit just below the executable; third-party
    groups anchor at the shared-deps rank.
    """
    if _entry_repo(name) == own_repo:
        return runfiles_groups.RANK_EXECUTABLE - 1
    return runfiles_groups.RANK_SHARED_DEPS

def _format_repo(repo_tuple):
    return repo_tuple[0] + "\0" + repo_tuple[1]

starlark_binary = rule(
    implementation = _starlark_binary_impl,
    executable = True,
    attrs = {
        "src": attr.label(
            allow_single_file = [".star", ".bzl"],
            mandatory = True,
            doc = "Starlark source file used as the entrypoint.",
        ),
        "deps": attr.label_list(
            providers = [StarlarkInfo],
            doc = "starlark_library targets providing source files.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files available at runtime.",
        ),
        "properties": attr.string_dict(
            doc = "Key-value properties accessible via get_property() at runtime. Values support $(location) expansion.",
        ),
        "interpreter": attr.label(
            default = Label("//producer/interpreter"),
            executable = True,
            cfg = "target",
            doc = "Starlark interpreter binary.",
        ),
        "runfiles_grouping": attr.string(
            default = "by_repo",
            values = ["by_repo", "by_target", "disabled"],
            doc = "How to group runfiles in RunfilesGroupInfo.",
        ),
        "repository": attr.string(
            default = "",
            doc = "Repository name for the load path. If empty, uses the main repo.",
        ),
        "_standard_library": attr.label(
            default = "@std",
        ),
        "_launcher": attr.label(
            default = "@hermetic_launcher//launcher/template:prebuilt",
            allow_single_file = True,
            cfg = "target",
        ),
        "_loadmap_generator": attr.label(
            default = Label("//producer/interpreter/loadmap"),
            executable = True,
            cfg = "exec",
        ),
        "_runfiles_group_callback": attr.label(
            default = Label("//producer/rules:starlark_binary_callback"),
        ),
    },
    toolchains = [
        launcher.finalizer_toolchain_type,
    ],
)
