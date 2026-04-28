"""Library for consuming and transforming RunfilesGroupInfo.

lib.ordered_groups(runfiles_group_info, selection_info = None)
    Returns a list of (group_name, depset[File]) tuples, filtered and
    sorted according to the selection. If selection_info is None, all
    groups are included in lexicographic order.

    The selection info supports two forms:
      List form (group_names / extra_group_treatment):
        Groups returned in the order given by group_names. Extras are
        excluded, prepended, or appended (lexicographically).
      Functional form (predicate / compare):
        Groups filtered by predicate and sorted by compare.

lib.transform_groups(runfiles_group_info, transform_info = None)
    Returns a new RunfilesGroupInfo with groups merged according to
    the transform. If transform_info is None, returns the input unchanged.

    The transform info supports two forms:
      Dict form (merge_groups / unmatched_group_treatment):
        Merges source groups into output groups per the mapping.
        Unmatched groups are excluded, kept separate, or merged into
        a default group.
      Functional form (transform):
        Calls transform(runfiles_group_info) and returns the result.
"""

load("//runfiles_group/private/providers:runfiles_group_info.bzl", "RunfilesGroupInfo")

def _ordered_groups(runfiles_group_info, runfiles_group_selection_info = None):
    all_names = dir(runfiles_group_info)
    selection = runfiles_group_selection_info

    if selection == None:
        ordered = sorted(all_names)
    elif selection.group_names != None:
        all_names_set = {name: True for name in all_names}
        listed = [name for name in selection.group_names if name in all_names_set]

        if selection.extra_group_treatment == "exclude":
            ordered = listed
        else:
            listed_set = {name: True for name in selection.group_names}
            extras = sorted([name for name in all_names if name not in listed_set])
            if selection.extra_group_treatment == "prepend":
                ordered = extras + listed
            else:
                ordered = listed + extras
    else:
        filtered = [name for name in all_names if selection.predicate(name)]
        ordered = _sort_with_compare(filtered, selection.compare)

    return [(name, getattr(runfiles_group_info, name)) for name in ordered]

def _sort_with_compare(items, compare):
    result = list(items)
    for i in range(1, len(result)):
        key = result[i]
        insert_at = i
        for j in range(i - 1, -1, -1):
            if compare(key, result[j]):
                result[j + 1] = result[j]
                insert_at = j
            else:
                break
        result[insert_at] = key
    return result

def _transform_groups(runfiles_group_info, runfiles_transform_info = None):
    if runfiles_transform_info == None:
        return runfiles_group_info
    if runfiles_transform_info.transform != None:
        return runfiles_transform_info.transform(runfiles_group_info)

    merge_groups = runfiles_transform_info.merge_groups
    treatment = runfiles_transform_info.unmatched_group_treatment
    all_names = dir(runfiles_group_info)
    all_names_set = {name: True for name in all_names}

    matched = {}
    for source_names in merge_groups.values():
        for source_name in source_names:
            matched[source_name] = True

    result = {}

    for out_name, source_names in merge_groups.items():
        depsets = [getattr(runfiles_group_info, name) for name in source_names if name in all_names_set]
        if depsets:
            result[out_name] = depset(transitive = depsets)

    unmatched = [name for name in all_names if name not in matched]

    if treatment == "keep_separate":
        for name in unmatched:
            result[name] = getattr(runfiles_group_info, name)
    elif treatment == "merge_default":
        default_depsets = [getattr(runfiles_group_info, name) for name in unmatched]
        if default_depsets:
            default_name = runfiles_transform_info.default_group_name
            if default_name in result:
                default_depsets.append(result[default_name])
            result[default_name] = depset(transitive = default_depsets)

    return RunfilesGroupInfo(**result)

lib = struct(
    ordered_groups = _ordered_groups,
    transform_groups = _transform_groups,
)
