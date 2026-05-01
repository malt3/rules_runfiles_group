_COLORS = {
    "black": "#000000",
    "white": "#ffffff",
    "red": "#ff0000",
    "green": "#00ff00",
    "blue": "#0000ff",
    "yellow": "#ffff00",
    "cyan": "#00ffff",
    "magenta": "#ff00ff",
    "gray": "#808080",
    "silver": "#c0c0c0",
    "maroon": "#800000",
    "olive": "#808000",
    "navy": "#000080",
    "teal": "#008080",
    "purple": "#800080",
    "orange": "#ffa500",
    "coral": "#ff7f50",
    "salmon": "#fa8072",
    "tomato": "#ff6347",
    "gold": "#ffd700",
    "khaki": "#f0e68c",
    "plum": "#dda0dd",
    "orchid": "#da70d6",
    "violet": "#ee82ee",
    "indigo": "#4b0082",
    "turquoise": "#40e0d0",
    "sienna": "#a0522d",
    "chocolate": "#d2691e",
    "crimson": "#dc143c",
    "aquamarine": "#7fffd4",
}

_FONT_SIZES = {
    "xs": "0.75rem",
    "sm": "0.875rem",
    "base": "1rem",
    "lg": "1.125rem",
    "xl": "1.25rem",
    "2xl": "1.5rem",
    "3xl": "1.875rem",
    "4xl": "2.25rem",
}

_SPACING = {
    "0": "0",
    "1": "0.25rem",
    "2": "0.5rem",
    "3": "0.75rem",
    "4": "1rem",
    "5": "1.25rem",
    "6": "1.5rem",
    "8": "2rem",
    "10": "2.5rem",
    "12": "3rem",
    "16": "4rem",
    "20": "5rem",
}

def _rule(selector, **properties):
    props = []
    for key, value in properties.items():
        css_key = key.replace("_", "-")
        props.append("  {}: {};".format(css_key, value))
    return selector + " {\n" + "\n".join(props) + "\n}"

def stylesheet(rules):
    return "\n\n".join(rules)

def color(name):
    return _COLORS.get(name, name)

def font_size(name):
    return _FONT_SIZES.get(name, name)

def spacing(name):
    return _SPACING.get(str(name), str(name))

def rule(selector, **properties):
    return _rule(selector, **properties)

def media_query(query, rules):
    inner = "\n".join(["  " + line for r in rules for line in r.split("\n")])
    return "@media {} {{\n{}\n}}".format(query, inner)

def reset_css():
    return stylesheet([
        _rule("*", margin = "0", padding = "0", box_sizing = "border-box"),
        _rule("html", font_size = "16px", line_height = "1.5"),
        _rule("body", font_family = "system-ui, -apple-system, sans-serif"),
        _rule("img", max_width = "100%", height = "auto"),
        _rule("a", color = "inherit", text_decoration = "none"),
        _rule("ul, ol", list_style = "none"),
        _rule("table", border_collapse = "collapse", width = "100%"),
    ])

def flex_container(direction = "row", wrap = "nowrap", justify = "flex-start", align = "stretch"):
    return {
        "display": "flex",
        "flex_direction": direction,
        "flex_wrap": wrap,
        "justify_content": justify,
        "align_items": align,
    }

def grid_container(columns = "1fr", rows = "auto", gap = "1rem"):
    return {
        "display": "grid",
        "grid_template_columns": columns,
        "grid_template_rows": rows,
        "gap": gap,
    }
