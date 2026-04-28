def repeat(s, n):
    parts = []
    for _ in range(n):
        parts.append(s)
    return "".join(parts)

def reverse(s):
    chars = list(s.elems())
    result = []
    for i in range(len(chars) - 1, -1, -1):
        result.append(chars[i])
    return "".join(result)

def words(s):
    return [w for w in s.split(" ") if w != ""]

def word_count(s):
    return len(words(s))
