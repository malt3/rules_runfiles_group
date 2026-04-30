"""A test verifying that RunfilesGroupInfo returned by a *_binary target is valid.

Usage:

```starlark
load("@rules_runfiles_group//runfiles_group:runfiles_group_analysis_test.bzl", "runfiles_group_analysis_test")

runfiles_group_analysis_test(
    name = "test_runfiles_group_invariants",
    binaries = [
        ":my_binary",
        ":my_other_binary",
    ],
    overlapping_group_behavior = "error",
)
```
"""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("//runfiles_group/private:lib.bzl", "lib")
load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")

_INDENT = "    "

def _indent(text):
    return "\n".join([_INDENT + line for line in text.split("\n")])

def _test_one(ctx, binary_attr):
    issues = []
    success = True
    default_info = binary_attr[DefaultInfo]
    default_runfiles = default_info.default_runfiles
    runfiles_group_info = binary_attr[RunfilesGroupInfo]
    if default_runfiles == None:
        return (False, ["doesn't have default_runfiles to compare to."])

    # Note: the following calculations are expensive.
    # This analysis test is only meant to be used to test the correctness of
    # RunfilesGroupInfo emitting rules. Do not use for all of your *_binary targets in prod.
    all_default_runfiles = sets.make(default_runfiles.files.to_list())
    all_grouped_runfiles = sets.make()
    for group_depset_name in lib.group_names(runfiles_group_info):
        group_depset = getattr(runfiles_group_info, group_depset_name)
        for file_from_group in group_depset.to_list():
            sets.insert(all_grouped_runfiles, file_from_group)

    # The most important property of RunfilesGroupInfo:
    # The union of all runfiles groups must result in the same set of files as DefaultInfo.default_runfiles
    runfiles_match = sets.is_equal(all_default_runfiles, all_grouped_runfiles)
    if not runfiles_match:
        success = False
        missing_from_groups = sets.difference(all_default_runfiles, all_grouped_runfiles)
        extra_in_groups = sets.difference(all_grouped_runfiles, all_default_runfiles)
        if sets.length(missing_from_groups) > 0:
            issues.append(
                "files in default_runfiles missing from RunfilesGroupInfo:\n" +
                "\n".join([_INDENT + f.short_path for f in sets.to_list(missing_from_groups)]),
            )
        if sets.length(extra_in_groups) > 0:
            issues.append(
                "files in RunfilesGroupInfo missing from default_runfiles:\n" +
                "\n".join([_INDENT + f.short_path for f in sets.to_list(extra_in_groups)]),
            )

    if ctx.attr.overlapping_group_behavior != "ignore":
        group_names = lib.group_names(runfiles_group_info)
        for i in range(len(group_names)):
            group_i = sets.make(getattr(runfiles_group_info, group_names[i]).to_list())
            for j in range(i + 1, len(group_names)):
                group_j = sets.make(getattr(runfiles_group_info, group_names[j]).to_list())
                overlap = sets.intersection(group_i, group_j)
                if sets.length(overlap) > 0:
                    msg = (
                        "groups '{}' and '{}' overlap:\n".format(
                            group_names[i],
                            group_names[j],
                        ) +
                        "\n".join([_INDENT + f.short_path for f in sets.to_list(overlap)])
                    )
                    if ctx.attr.overlapping_group_behavior == "error":
                        success = False
                        issues.append(msg)
                    else:
                        # buildifier: disable=print
                        print("WARNING [{}]: {}".format(binary_attr.label, msg))

    return (success, issues)

def _runfiles_group_analysis_test_impl(ctx):
    if len(ctx.attr.binaries) == 0:
        return [AnalysisTestResultInfo(
            success = False,
            message = "runfiles_group_analysis_test with no binaries.",
        )]

    results = []
    for binary_attr in ctx.attr.binaries:
        results.append((binary_attr.label, _test_one(ctx, binary_attr)))

    success = True
    sections = []
    for label, result in results:
        if not result[0]:
            success = False
            if len(result[1]) > 0:
                sections.append(
                    "Issues with {}:\n{}".format(
                        label,
                        "\n".join([_indent(issue) for issue in result[1]]),
                    ),
                )

    return [AnalysisTestResultInfo(
        success = success,
        message = "\n".join(sections),
    )]

runfiles_group_analysis_test = rule(
    implementation = _runfiles_group_analysis_test_impl,
    doc = """\
Checks that RunfilesGroupInfo is well formed by comparing the runfiles of the executable (DefaultInfo.default_runfiles.files)
with the union of all runfiles from RunfilesGroupInfo.

Additionally, it can warn about files appearing in multiple groups (overlapping).
""",
    attrs = {
        "binaries": attr.label_list(
            cfg = "target",
            mandatory = True,
            providers = [RunfilesGroupInfo],
            doc = "List of *_binary targets to test.",
        ),
        "overlapping_group_behavior": attr.string(
            doc = "How to handle overlapping groups (the same file being present in more than one group).",
            default = "warn",
            values = ["warn", "ignore", "error"],
        ),
    },
    analysis_test = True,
)
