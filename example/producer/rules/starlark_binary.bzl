"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")
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
        groups = {}

        dep_groups = lib.collect_groups(ctx, ctx.attr.deps)
        data_groups = lib.collect_groups(ctx, ctx.attr.data)
        dep_metadata = lib.merge_metadata(dep_groups.metadata, data_groups.metadata)

        metadata = {}
        own_repo = ctx.attr.repository

        # Special group: interpreter
        groups[_GROUP_PREFIX + "interpreter"] = ctx.runfiles(
            files = [interpreter_exe],
        ).merge(interpreter_info.default_runfiles)
        metadata[_GROUP_PREFIX + "interpreter"] = lib.group_metadata(rank = lib.RANK_FOUNDATION, do_not_merge = True, merge_affinity = _AFFINITY)

        # Special group: std
        groups[_GROUP_PREFIX + "std"] = stdlib[DefaultInfo].default_runfiles
        metadata[_GROUP_PREFIX + "std"] = lib.group_metadata(rank = _RANK_STD, merge_affinity = _AFFINITY)

        # Dep groups
        if ctx.attr.runfiles_grouping == "by_target":
            groups.update(data_groups.groups)
            groups[_GROUP_PREFIX + "entrypoint"] = entrypoint_runfiles
            metadata[_GROUP_PREFIX + "entrypoint"] = lib.group_metadata(rank = lib.RANK_EXECUTABLE, executable_group = True, merge_affinity = _AFFINITY)
            for name in data_groups.groups:
                metadata[name] = _dep_group_metadata(dep_metadata, name, own_repo)
            for name, rf in dep_groups.groups.items():
                groups[name] = rf
                metadata[name] = _dep_group_metadata(dep_metadata, name, own_repo)

        elif ctx.attr.runfiles_grouping == "by_repo":
            repo_runfiles = {}
            repo_weights = {}
            repo_runfiles[own_repo] = [entrypoint_runfiles]
            all_dep_groups = {}
            all_dep_groups.update(data_groups.groups)
            all_dep_groups.update(dep_groups.groups)
            repo_affinities = {}
            for name, rf in all_dep_groups.items():
                repo = _extract_repo(name)
                if repo not in repo_runfiles:
                    repo_runfiles[repo] = []
                repo_runfiles[repo].append(rf)
                w = _get_dep_weight(dep_metadata, name)
                if w != None:
                    repo_weights[repo] = repo_weights.get(repo, 0) + w

                # A repo group aggregates its members' groups. Adopt a member's
                # affinity if one is set; data deps without RunfilesGroupInfo
                # contribute the empty affinity and never override it.
                affinity = _get_dep_affinity(dep_metadata, name)
                if affinity:
                    repo_affinities[repo] = affinity
            for repo, rs in repo_runfiles.items():
                group_name = _GROUP_PREFIX + (repo or "_main")
                groups[group_name] = rs[0] if len(rs) == 1 else rs[0].merge_all(rs[1:])
                if repo == own_repo:
                    metadata[group_name] = lib.group_metadata(rank = lib.RANK_EXECUTABLE, weight = repo_weights.get(repo, None), executable_group = True, merge_affinity = _AFFINITY)
                else:
                    metadata[group_name] = lib.group_metadata(rank = lib.RANK_SHARED_DEPS, weight = repo_weights.get(repo, None), merge_affinity = repo_affinities.get(repo, ""))

        providers.append(RunfilesGroupInfo(**groups))
        providers.append(RunfilesGroupMetadataInfo(groups = metadata))

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

def _get_dep_weight(dep_metadata, name):
    if dep_metadata == None:
        return None
    entry = dep_metadata.groups.get(name, None)
    if entry == None:
        return None
    return entry.weight

def _get_dep_affinity(dep_metadata, name):
    if dep_metadata == None:
        return ""
    entry = dep_metadata.groups.get(name, None)
    if entry == None:
        return ""
    return entry.merge_affinity

def _dep_group_metadata(dep_metadata, name, own_repo):
    """Metadata for a collected dep/data group in by_target grouping.

    First-party (own-repo) groups sit just below the executable; third-party
    groups anchor at the shared-deps rank. Weight and merge_affinity are carried
    through from the collected metadata so the packager can merge intelligently.
    """
    weight = _get_dep_weight(dep_metadata, name)
    affinity = _get_dep_affinity(dep_metadata, name)
    if _extract_repo(name) == own_repo:
        rank = lib.RANK_EXECUTABLE - 1
    else:
        rank = lib.RANK_SHARED_DEPS
    return lib.group_metadata(rank = rank, weight = weight, merge_affinity = affinity)

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
