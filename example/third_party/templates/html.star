_ELEMENTS = {
    "div": {"self_closing": False, "block": True},
    "span": {"self_closing": False, "block": False},
    "p": {"self_closing": False, "block": True},
    "a": {"self_closing": False, "block": False},
    "img": {"self_closing": True, "block": False},
    "br": {"self_closing": True, "block": False},
    "hr": {"self_closing": True, "block": True},
    "h1": {"self_closing": False, "block": True},
    "h2": {"self_closing": False, "block": True},
    "h3": {"self_closing": False, "block": True},
    "h4": {"self_closing": False, "block": True},
    "h5": {"self_closing": False, "block": True},
    "h6": {"self_closing": False, "block": True},
    "ul": {"self_closing": False, "block": True},
    "ol": {"self_closing": False, "block": True},
    "li": {"self_closing": False, "block": True},
    "table": {"self_closing": False, "block": True},
    "tr": {"self_closing": False, "block": True},
    "td": {"self_closing": False, "block": False},
    "th": {"self_closing": False, "block": False},
    "thead": {"self_closing": False, "block": True},
    "tbody": {"self_closing": False, "block": True},
    "form": {"self_closing": False, "block": True},
    "input": {"self_closing": True, "block": False},
    "button": {"self_closing": False, "block": False},
    "select": {"self_closing": False, "block": False},
    "option": {"self_closing": False, "block": False},
    "textarea": {"self_closing": False, "block": False},
    "label": {"self_closing": False, "block": False},
    "section": {"self_closing": False, "block": True},
    "article": {"self_closing": False, "block": True},
    "header": {"self_closing": False, "block": True},
    "footer": {"self_closing": False, "block": True},
    "nav": {"self_closing": False, "block": True},
    "main": {"self_closing": False, "block": True},
    "aside": {"self_closing": False, "block": True},
    "pre": {"self_closing": False, "block": True},
    "code": {"self_closing": False, "block": False},
    "blockquote": {"self_closing": False, "block": True},
}

def _escape(text):
    result = text
    result = result.replace("&", "&amp;")
    result = result.replace("<", "&lt;")
    result = result.replace(">", "&gt;")
    result = result.replace('"', "&quot;")
    return result

def _render_attrs(attrs):
    parts = []
    for key, value in attrs.items():
        parts.append('{}="{}"'.format(key, _escape(str(value))))
    if parts:
        return " " + " ".join(parts)
    return ""

def element(tag, content = "", **attrs):
    info = _ELEMENTS.get(tag, {"self_closing": False, "block": True})
    attr_str = _render_attrs(attrs)
    if info["self_closing"]:
        return "<{}{} />".format(tag, attr_str)
    return "<{}{}>{}</{}>".format(tag, attr_str, content, tag)

def document(title, body):
    return "\n".join([
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        "  <meta charset=\"utf-8\" />",
        "  <title>{}</title>".format(_escape(title)),
        "</head>",
        "<body>",
        body,
        "</body>",
        "</html>",
    ])

def list_items(items, ordered = False):
    tag = "ol" if ordered else "ul"
    li_parts = [element("li", _escape(str(item))) for item in items]
    return element(tag, "\n".join(li_parts))

def table(headers, rows):
    header_cells = [element("th", _escape(str(h))) for h in headers]
    header_row = element("tr", "".join(header_cells))
    thead = element("thead", header_row)
    body_rows = []
    for row in rows:
        cells = [element("td", _escape(str(cell))) for cell in row]
        body_rows.append(element("tr", "".join(cells)))
    tbody = element("tbody", "\n".join(body_rows))
    return element("table", thead + "\n" + tbody)

def link(href, text):
    return element("a", _escape(text), href = href)

def image(src, alt = ""):
    return element("img", src = src, alt = alt)

def heading(level, text):
    tag = "h" + str(level)
    return element(tag, _escape(text))

def form_input(name, input_type = "text", value = "", placeholder = ""):
    return element("input", type = input_type, name = name, value = value, placeholder = placeholder)

def paragraph(text):
    return element("p", _escape(text))
