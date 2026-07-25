"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

_GROUP_PREFIX = "starlark_runfiles_group#"

# Merge affinity stamped on every group this ruleset produces. See the
# matching comment in starlark_library.bzl.
_AFFINITY = "starlark"

# Module-level so the boxed int is allocated once at load time. StarlarkInt only
# caches [-128, 99871], so evaluating `lib.RANK_FOUNDATION + 100` in the rule
# implementation would allocate a fresh 16-byte object per target and retain it
# inside the metadata struct.
_RANK_STD = lib.RANK_FOUNDATION + 100

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
    # The entrypoint bundle is built once and reused as the "entrypoint" group
    # value below, so the two are the same object. The executable is already part
    # of default_runfiles for an executable Starlark rule, so naming it here
    # changes nothing about the contents.
    entrypoint_runfiles = ctx.runfiles(files = [output, entrypoint, loadmap, properties])

    # One merge_all rather than a fold: see the comment in starlark_library.bzl.
    to_merge = [
        interpreter_info.default_runfiles,
        stdlib[DefaultInfo].default_runfiles,
    ]
    if ctx.files.data:
        to_merge.append(ctx.runfiles(files = ctx.files.data))
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.deps])
    to_merge.extend([dep[DefaultInfo].default_runfiles for dep in ctx.attr.data])
    runfiles = entrypoint_runfiles.merge_all(to_merge)

    providers = [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
    ]

    # Honor the global on/off switch: emit no RunfilesGroupInfo when disabled.
    if not lib.is_enabled(ctx):
        return providers

    if ctx.attr.runfiles_grouping != "disabled":
        own_repo = ctx.attr.repository

        # Both grouping modes re-shape the collected groups, so this binary is a
        # "materializing" target: it flattens the dependencies' entry depset once.
        # A *_library must never do this -- it only ever calls lib.collect().
        collected = lib.resolve(
            lib.collect(ctx, deps = ctx.attr.deps, data = ctx.attr.data),
            aspect_hints = [],
        )

        entries = [
            # Special group: interpreter.
            lib.entry(
                name = _GROUP_PREFIX + "interpreter",
                runfiles = ctx.runfiles(files = [interpreter_exe]).merge(interpreter_info.default_runfiles),
                kind = "foundation",
                rank = lib.RANK_FOUNDATION,
                do_not_merge = True,
                merge_affinity = _AFFINITY,
            ),
            # Special group: std.
            lib.entry(
                name = _GROUP_PREFIX + "std",
                runfiles = stdlib[DefaultInfo].default_runfiles,
                kind = "foundation",
                rank = _RANK_STD,
                merge_affinity = _AFFINITY,
            ),
        ]

        if ctx.attr.runfiles_grouping == "by_target":
            # One group per transitive target, re-ranked relative to this binary.
            # lib.derive carries weight, merge_affinity and kind through, so
            # re-ranking cannot silently reset them.
            executable_group = _GROUP_PREFIX + "entrypoint"
            entries.append(lib.entry(
                name = executable_group,
                runfiles = entrypoint_runfiles,
                kind = "first_party",
                rank = lib.RANK_EXECUTABLE,
                merge_affinity = _AFFINITY,
            ))
            if collected != None:
                for entry in collected.groups:
                    entries.append(lib.derive(entry, rank = _dep_rank(entry.name, own_repo)))

        elif ctx.attr.runfiles_grouping == "by_repo":
            # One group per repository. Members' weights are summed, and their
            # affinity and kind adopted, so the aggregate still carries usable
            # merge hints.
            repo_runfiles = {own_repo: [entrypoint_runfiles]}
            repo_weights = {}
            repo_affinities = {}
            repo_kinds = {}
            if collected != None:
                for entry in collected.groups:
                    repo = _extract_repo(entry.name)
                    repo_runfiles.setdefault(repo, []).append(entry.runfiles)
                    if entry.weight != None:
                        repo_weights[repo] = repo_weights.get(repo, 0) + entry.weight

                    # Data deps without RunfilesGroupInfo contribute the empty
                    # affinity and kind, which never override a member's.
                    if entry.merge_affinity:
                        repo_affinities[repo] = entry.merge_affinity
                    if entry.kind:
                        repo_kinds[repo] = entry.kind

            executable_group = _GROUP_PREFIX + (own_repo or "_main")
            for repo, parts in repo_runfiles.items():
                group_name = _GROUP_PREFIX + (repo or "_main")
                merged = parts[0] if len(parts) == 1 else parts[0].merge_all(parts[1:])
                if repo == own_repo:
                    entries.append(lib.entry(
                        name = group_name,
                        runfiles = merged,
                        kind = "first_party",
                        rank = lib.RANK_EXECUTABLE,
                        weight = repo_weights.get(repo, None),
                        merge_affinity = _AFFINITY,
                    ))
                else:
                    entries.append(lib.entry(
                        name = group_name,
                        runfiles = merged,
                        kind = repo_kinds.get(repo, ""),
                        rank = lib.RANK_SHARED_DEPS,
                        weight = repo_weights.get(repo, None),
                        merge_affinity = repo_affinities.get(repo, ""),
                    ))

        providers.append(RunfilesGroupInfo(
            entries = lib.entries(entries),
            executable_group = executable_group,
        ))

    return providers

def _extract_repo(group_name):
    """Extracts the friendly repo name from a group name.

    "starlark_runfiles_group#@fizzbuzz//:fizzbuzz" -> "fizzbuzz"
    "starlark_runfiles_group#//src:lib_a" -> ""
    "data#@@fizzbuzz//pkg:target" -> "fizzbuzz"
    "data#@@//src:a.txt" -> ""
    """
    if group_name.startswith(_GROUP_PREFIX):
        group_name = group_name[len(_GROUP_PREFIX):]
    elif group_name.startswith("data#"):
        group_name = group_name[len("data#"):]
    if group_name.startswith("@@"):
        group_name = group_name[1:]
    if not group_name.startswith("@"):
        return ""
    idx = group_name.find("//")
    if idx < 0:
        return ""
    return group_name[1:idx]

def _dep_rank(name, own_repo):
    """Rank for a collected dep/data group in by_target grouping.

    First-party (own-repo) groups sit just below the executable; third-party
    groups anchor at the shared-deps rank.
    """
    if _extract_repo(name) == own_repo:
        return lib.RANK_EXECUTABLE - 1
    return lib.RANK_SHARED_DEPS

def _format_repo(repo_tuple):
    return repo_tuple[0] + "\0" + repo_tuple[1]

starlark_binary = rule(
    implementation = _starlark_binary_impl,
    executable = True,
    attrs = dict({
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
    }, **lib.RULE_ATTRS),
    toolchains = [
        launcher.finalizer_toolchain_type,
    ],
)
