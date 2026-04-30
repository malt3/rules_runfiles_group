# A simple example app that uses the "std" library we made up together with a data dependency and a custom builtin (read_file).
load("@std//sha256:sha256.star", "sha256")

print(sha256(read_file(get_property("IRS_F1040_PATH"))))
