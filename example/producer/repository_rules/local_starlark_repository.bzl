def _local_starlark_repository_impl(rctx):
    repo_root = rctx.path(rctx.attr.repo_file).dirname
    rctx.watch(repo_root)

    simple_name = rctx.name.split("~")[-1].split("+")[-1]
    main_module = rctx.attr.main_module

    # Find all .star files under repo_root.
    result = rctx.execute(
        ["find", str(repo_root), "-name", "*.star", "-type", "f"],
        quiet = True,
    )
    star_files = [f for f in result.stdout.strip().split("\n") if f]

    # packages: map from package path (relative to repo root, "" for root) to list of (filename, byte_size).
    packages = {}
    root_str = str(repo_root)
    for abs_path in star_files:
        rel = abs_path[len(root_str) + 1:]
        idx = rel.rfind("/")
        if idx < 0:
            pkg = ""
            filename = rel
        else:
            pkg = rel[:idx]
            filename = rel[idx + 1:]
        if pkg not in packages:
            packages[pkg] = []
        size = len(rctx.read(abs_path))
        packages[pkg].append((filename, size))
        dest = rel if pkg else filename
        rctx.symlink(abs_path, dest)

    # Copy external files.
    for label, dest in rctx.attr.copy_files.items():
        src_path = rctx.path(label)
        size = len(rctx.read(src_path))
        rctx.symlink(src_path, dest)
        idx = dest.rfind("/")
        if idx < 0:
            pkg = ""
            filename = dest
        else:
            pkg = dest[:idx]
            filename = dest[idx + 1:]
        if pkg not in packages:
            packages[pkg] = []
        packages[pkg].append((filename, size))

    # Generate BUILD files.
    sub_packages = sorted([pkg for pkg in packages if pkg != ""])

    for pkg, files in packages.items():
        total_weight = 0
        for _, size in files:
            total_weight += size
        target_name = pkg.rsplit("/", 1)[-1] if pkg else simple_name
        srcs = sorted([f for f, _ in files])
        path = "{}/BUILD.bazel".format(pkg) if pkg else "BUILD.bazel"
        _write_build_file(rctx, path, target_name, srcs, simple_name, total_weight, [], main_module)

    # Root umbrella target: if there are sub-packages, ensure a root target exists that deps on them all.
    root_deps = ["//" + pkg + ":" + pkg.rsplit("/", 1)[-1] for pkg in sub_packages]
    if "" in packages:
        root_files = packages[""]
        total_weight = 0
        for _, size in root_files:
            total_weight += size
        srcs = sorted([f for f, _ in root_files])
        _write_build_file(rctx, "BUILD.bazel", simple_name, srcs, simple_name, total_weight, root_deps, main_module)
    else:
        _write_build_file(rctx, "BUILD.bazel", simple_name, [], simple_name, 0, root_deps, main_module)

    rctx.file("REPO.bazel", "")

def _write_build_file(rctx, path, target_name, srcs, repository, weight, deps, main_module):
    lines = []
    lines.append('load("@{}//producer/rules:starlark_library.bzl", "starlark_library")'.format(main_module))
    lines.append("")
    lines.append("starlark_library(")
    lines.append('    name = "{}",'.format(target_name))
    if srcs:
        if len(srcs) == 1:
            lines.append('    srcs = ["{}"],'.format(srcs[0]))
        else:
            lines.append("    srcs = [")
            for src in srcs:
                lines.append('        "{}",'.format(src))
            lines.append("    ],")
    lines.append('    repository = "{}",'.format(repository))
    if weight > 0:
        lines.append("    runfiles_weight = {},".format(weight))
    lines.append('    visibility = ["//visibility:public"],')
    if deps:
        if len(deps) == 1:
            lines.append('    deps = ["{}"],'.format(deps[0]))
        else:
            lines.append("    deps = [")
            for dep in sorted(deps):
                lines.append('        "{}",'.format(dep))
            lines.append("    ],")
    lines.append(")")
    lines.append("")
    rctx.file(path, "\n".join(lines))

local_starlark_repository = repository_rule(
    implementation = _local_starlark_repository_impl,
    attrs = {
        "repo_file": attr.label(
            mandatory = True,
            doc = "REPO.bazel of the local starlark repository. .star files are discovered relative to this file's directory.",
        ),
        "copy_files": attr.label_keyed_string_dict(
            doc = "Map of source labels to destination paths within the repo. Use for files that live outside the source directory (e.g., '@sha256.bzl//:sha256.star': 'sha256/sha256.star').",
        ),
        "main_module": attr.string(
            default = "rules_runfiles_group_example",
            doc = "Name of the main module that provides starlark_library.",
        ),
    },
)
