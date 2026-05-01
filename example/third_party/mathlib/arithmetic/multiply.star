def multiply(a, b):
    return a * b

def divide(a, b):
    if b == 0:
        fail("division by zero")
    return a / b

def power(base, exp):
    result = 1
    for _ in range(exp):
        result = result * base
    return result

def factorial(n):
    if n < 0:
        fail("factorial of negative number")
    result = 1
    for i in range(1, n + 1):
        result = result * i
    return result

def product_list(items):
    result = 1
    for item in items:
        result = result * item
    return result
