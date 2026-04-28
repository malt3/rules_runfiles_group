"""Implementation of the starlark_binary rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("@rules_runfiles_group//runfiles_group:providers.bzl", "RunfilesGroupInfo", "RunfilesGroupSelectionInfo")
load("//producer/providers:providers.bzl", "StarlarkInfo")

def _starlark_binary_impl(ctx):
    interpreter_info = ctx.attr.interpreter[DefaultInfo]
    interpreter_exe = interpreter_info.files_to_run.executable
    entrypoint = ctx.file.src

    # Collect repos from all deps + self + standard library
    transitive_repos = [dep[StarlarkInfo].repos for dep in ctx.attr.deps]
    stdlib = ctx.attr._standard_library
    all_repos = depset(
        [
            (ctx.attr.repository, ctx.label.repo_name),
            ("std", stdlib.label.repo_name),
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

    # Build launcher stub: interpreter --loadmap <loadmap> <entrypoint>
    embedded_args, transformed_args = launcher.args_from_entrypoint(interpreter_exe)
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
    embedded_args, transformed_args = launcher.append_runfile(
        file = entrypoint,
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
    runfiles = ctx.runfiles(files = [entrypoint, loadmap] + ctx.files.data)
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
        ranks = {"interpreter": 0, "std": 1}

        # Special group: interpreter
        groups["interpreter"] = depset(
            [interpreter_exe],
            transitive = [interpreter_info.default_runfiles.files],
        )

        # Special group: std
        groups["std"] = stdlib[DefaultInfo].default_runfiles.files

        entrypoint_files = depset([output, entrypoint, loadmap] + ctx.files.data)

        # Dep groups
        current_repo = ctx.label.repo_name
        if ctx.attr.runfiles_grouping == "by_target":
            # Keep a separate entrypoint group in by_target mode.
            groups["entrypoint"] = entrypoint_files
            ranks["entrypoint"] = 3
            for dep in ctx.attr.deps:
                if RunfilesGroupInfo in dep:
                    for name in dir(dep[RunfilesGroupInfo]):
                        groups[name] = getattr(dep[RunfilesGroupInfo], name)
                        if _extract_repo(name) == current_repo:
                            ranks[name] = 3

        elif ctx.attr.runfiles_grouping == "by_repo":
            # Merge entrypoint into the current repo group.
            repo_depsets = {}
            repo_depsets[current_repo] = [entrypoint_files]
            ranks[current_repo] = 3
            for dep in ctx.attr.deps:
                if RunfilesGroupInfo in dep:
                    for name in dir(dep[RunfilesGroupInfo]):
                        repo = _extract_repo(name)
                        if repo not in repo_depsets:
                            repo_depsets[repo] = []
                        repo_depsets[repo].append(getattr(dep[RunfilesGroupInfo], name))
            for repo, ds in repo_depsets.items():
                groups[repo] = depset(transitive = ds)
                if repo == current_repo:
                    ranks[repo] = 3

        providers.append(RunfilesGroupInfo(**groups))
        providers.append(RunfilesGroupSelectionInfo(
            predicate = _predicate_all,
            compare = lambda left, right: _compare_starlark_binary_order(ranks, left, right),
        ))

    return providers

def _extract_repo(label_str):
    idx = label_str.find("//")
    if idx <= 0:
        return "_main"
    repo = label_str[:idx]
    if repo.startswith("@@"):
        repo = repo[2:]
    elif repo.startswith("@"):
        repo = repo[1:]
    return repo if repo else "_main"

def _format_repo(repo_tuple):
    return repo_tuple[0] + "\0" + repo_tuple[1]

def _predicate_all(_):
    return True

# Rank: 0 = interpreter, 1 = std, 2 = third-party deps, 3 = current repo
def _compare_starlark_binary_order(ranks, left, right):
    left_rank = ranks.get(left, 2)
    right_rank = ranks.get(right, 2)
    if left_rank != right_rank:
        return left_rank < right_rank
    return left < right

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
