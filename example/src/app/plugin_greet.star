"""The "greet" plugin, registered under that id by the app's plugins attribute."""

def handle(name):
    return "hello, %s" % name
