"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:lib.bzl", "lib")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupMetadataInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

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

    # Runfiles: interpreter + entrypoint + loadmap + stdlib + data + all deps
    runfiles = ctx.runfiles(files = [entrypoint, loadmap, properties] + ctx.files.data)
    runfiles = runfiles.merge(interpreter_info.default_runfiles)
    runfiles = runfiles.merge(stdlib[DefaultInfo].default_runfiles)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    for dep in ctx.attr.data:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    providers = [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
    ]

    if ctx.attr.runfiles_grouping != "disabled":
        groups = {}

        # Collect metadata from deps (carries weight from starlark_library).
        dep_metadata = None
        for dep in ctx.attr.deps:
            if RunfilesGroupMetadataInfo in dep:
                dep_metadata = lib.merge_metadata(dep_metadata, dep[RunfilesGroupMetadataInfo])

        metadata = {}
        own_repo = ctx.attr.repository

        # Special group: interpreter
        groups["interpreter"] = depset(
            [interpreter_exe],
            transitive = [interpreter_info.default_runfiles.files],
        )
        metadata["interpreter"] = lib.group_metadata(rank = -2, do_not_merge = True)

        # Special group: std
        groups["std"] = stdlib[DefaultInfo].default_runfiles.files
        metadata["std"] = lib.group_metadata(rank = -1)

        entrypoint_files = depset([output, entrypoint, loadmap, properties] + ctx.files.data)

        # Dep groups
        if ctx.attr.runfiles_grouping == "by_target":
            groups["entrypoint"] = entrypoint_files
            metadata["entrypoint"] = lib.group_metadata(rank = 2)
            for dep in ctx.attr.deps:
                if RunfilesGroupInfo in dep:
                    for name in lib.group_names(dep[RunfilesGroupInfo]):
                        groups[name] = getattr(dep[RunfilesGroupInfo], name)
                        dep_weight = _get_dep_weight(dep_metadata, name)
                        if _extract_repo(name) == own_repo:
                            metadata[name] = lib.group_metadata(rank = 1, weight = dep_weight)
                        elif dep_weight != None:
                            metadata[name] = lib.group_metadata(weight = dep_weight)

        elif ctx.attr.runfiles_grouping == "by_repo":
            repo_depsets = {}
            repo_weights = {}
            repo_depsets[own_repo] = [entrypoint_files]
            for dep in ctx.attr.deps:
                if RunfilesGroupInfo in dep:
                    for name in lib.group_names(dep[RunfilesGroupInfo]):
                        repo = _extract_repo(name)
                        if repo not in repo_depsets:
                            repo_depsets[repo] = []
                        repo_depsets[repo].append(getattr(dep[RunfilesGroupInfo], name))
                        w = _get_dep_weight(dep_metadata, name)
                        if w != None:
                            repo_weights[repo] = repo_weights.get(repo, 0) + w
            for repo, ds in repo_depsets.items():
                groups[repo or "_main"] = depset(transitive = ds)
                if repo == own_repo:
                    metadata[repo or "_main"] = lib.group_metadata(rank = 1, weight = repo_weights.get(repo, None))
                elif repo in repo_weights:
                    metadata[repo or "_main"] = lib.group_metadata(weight = repo_weights[repo])

        providers.append(RunfilesGroupInfo(**groups))
        providers.append(RunfilesGroupMetadataInfo(groups = metadata))

    return providers

def _extract_repo(group_name):
    """Extracts the friendly repo name from a loadpath-based group name.

    "@fizzbuzz//:fizzbuzz" -> "fizzbuzz"
    "//src:lib_a" -> ""
    """
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
            default = Label("//producer/interpreter/loadmap_generator"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        launcher.finalizer_toolchain_type,
    ],
)
