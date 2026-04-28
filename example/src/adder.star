load("@std//sha256:sha256.star", "sha256")
load("lib_a.star", "get_a")
load("lib_b.star", "get_b")

result = get_a() + get_b()
print("Result: %d" % result)
print("sha256(\"%d\") = %s" % (result, sha256(str(result))))
