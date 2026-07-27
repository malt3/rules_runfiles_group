"""The "clock" plugin. Also a plain dep of the app, to show that a library reached
through two attributes still ends up in exactly one runfiles group."""

def handle(tick):
    return "tick %d" % tick
