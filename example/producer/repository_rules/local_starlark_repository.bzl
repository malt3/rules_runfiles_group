def _local_starlark_repository_impl(rctx):
    rctx.watch(rctx.attr.repo_file)
    repo_root = rctx.path(rctx.attr.repo_file).dirname
    rctx.watch(repo_root)
    rctx.symlink(repo_root, ".")

local_starlark_repository = repository_rule(
    implementation = _local_starlark_repository_impl,
    attrs = {"repo_file": attr.label(
        mandatory = True,
        doc = "REPO.bazel of the local starlark repository",
    )},
)
