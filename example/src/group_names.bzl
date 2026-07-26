"""Canonical repository names, which vary with the Bazel version and the module setup.

The `by_repo` grouping mode of `starlark_binary` names its groups after the
*canonical* repository of the targets in them, because that is what a per-target
group's Label reports. Those names are not stable enough to hard-code in
expectations, so they are computed here from the labels themselves.
"""

def repo(label):
    """Canonical repository name of a label, or "_main" for the main repository."""
    return label.repo_name or "_main"

IRS_F1040 = repo(Label("@irs_f1040//file"))
FIZZBUZZ = repo(Label("@fizzbuzz//:fizzbuzz"))
STRINGUTIL = repo(Label("@stringutil//:stringutil"))
COLORS = repo(Label("@colors//:colors"))
LIMITS = repo(Label("@limits//:limits"))
MATHLIB = repo(Label("@mathlib//:mathlib"))
TEMPLATES = repo(Label("@templates//:templates"))
UNITS = repo(Label("@units//:units"))
