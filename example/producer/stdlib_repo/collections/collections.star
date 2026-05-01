def sorted_list(items, reverse = False):
    result = list(items)
    for i in range(len(result)):
        for j in range(i + 1, len(result)):
            swap = result[i] > result[j] if not reverse else result[i] < result[j]
            if swap:
                result[i], result[j] = result[j], result[i]
    return result

def unique(items):
    seen = {}
    result = []
    for item in items:
        key = str(item)
        if key not in seen:
            seen[key] = True
            result.append(item)
    return result

def group_by(items, key_fn):
    groups = {}
    for item in items:
        key = key_fn(item)
        if key not in groups:
            groups[key] = []
        groups[key].append(item)
    return groups

def flatten(nested):
    result = []
    for item in nested:
        if type(item) == "list":
            result.extend(flatten(item))
        else:
            result.append(item)
    return result

def chunk(items, size):
    result = []
    current = []
    for item in items:
        current.append(item)
        if len(current) == size:
            result.append(current)
            current = []
    if current:
        result.append(current)
    return result

def zip_lists(a, b):
    result = []
    for i in range(min(len(a), len(b))):
        result.append((a[i], b[i]))
    return result

def take(items, n):
    return items[:n]

def drop(items, n):
    return items[n:]
