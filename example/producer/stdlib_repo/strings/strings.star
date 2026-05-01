def join(separator, items):
    result = ""
    for i, item in enumerate(items):
        if i > 0:
            result += separator
        result += str(item)
    return result

def split(s, separator):
    parts = []
    sep_len = len(separator)
    start = 0
    for i in range(len(s)):
        if i < start:
            continue
        if s[i:i + sep_len] == separator:
            parts.append(s[start:i])
            start = i + sep_len
    parts.append(s[start:])
    return parts

def trim(s):
    start = 0
    end = len(s)
    for i in range(len(s)):
        if s[i] != " " and s[i] != "\t" and s[i] != "\n":
            start = i
            break
    for i in range(len(s) - 1, -1, -1):
        if s[i] != " " and s[i] != "\t" and s[i] != "\n":
            end = i + 1
            break
    return s[start:end]

def repeat(s, n):
    result = ""
    for _ in range(n):
        result += s
    return result

def pad_left(s, width, fill = " "):
    if len(s) < width:
        s = repeat(fill, width - len(s)) + s
    return s

def pad_right(s, width, fill = " "):
    if len(s) < width:
        s = s + repeat(fill, width - len(s))
    return s

def contains(s, substr):
    return s.find(substr) >= 0

def starts_with(s, prefix):
    return s[:len(prefix)] == prefix

def ends_with(s, suffix):
    return s[len(s) - len(suffix):] == suffix
