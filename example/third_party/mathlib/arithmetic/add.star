def add(a, b):
    return a + b

def subtract(a, b):
    return a - b

def negate(a):
    return -a

def sum_list(items):
    result = 0
    for item in items:
        result = result + item
    return result

def running_sum(items):
    result = []
    total = 0
    for item in items:
        total = total + item
        result.append(total)
    return result
