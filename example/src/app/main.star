load("core.star", "plugin_order")
load("plugin_greet.star", "handle")

print("plugins: %s" % plugin_order({"plugins": {"greet": "//src/app"}}))
print(handle("world"))
