"""The app's entry library: it turns a registry into a load order."""

def plugin_order(registry):
    return sorted(registry["plugins"].keys())
