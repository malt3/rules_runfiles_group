"""Public API for runfiles group providers."""

load("//runfiles_group/private/providers:runfiles_group_info.bzl", _RunfilesGroupInfo = "RunfilesGroupInfo")
load("//runfiles_group/private/providers:runfiles_group_metadata_info.bzl", _RunfilesGroupMetadataInfo = "RunfilesGroupMetadataInfo")
load("//runfiles_group/private/providers:runfiles_group_transform_info.bzl", _RunfilesGroupTransformInfo = "RunfilesGroupTransformInfo")

RunfilesGroupInfo = _RunfilesGroupInfo
RunfilesGroupMetadataInfo = _RunfilesGroupMetadataInfo
RunfilesGroupTransformInfo = _RunfilesGroupTransformInfo
