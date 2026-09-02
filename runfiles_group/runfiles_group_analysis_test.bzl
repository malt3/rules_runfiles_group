"""Public API for runfiles_group_analysis_test."""

load(
    "//runfiles_group/private/rules:runfiles_group_analysis_test.bzl",
    _make_runfiles_group_analysis_test = "make_runfiles_group_analysis_test",
    _runfiles_group_analysis_test = "runfiles_group_analysis_test",
)

runfiles_group_analysis_test = _runfiles_group_analysis_test
make_runfiles_group_analysis_test = _make_runfiles_group_analysis_test
