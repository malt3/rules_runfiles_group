PI = 3.14159265358979323846
E = 2.71828182845904523536
TAU = 6.28318530717958647692
GOLDEN_RATIO = 1.61803398874989484820

def clamp(value, low, high):
    if value < low:
        return low
    if value > high:
        return high
    return value

def lerp(a, b, t):
    return a + (b - a) * t
