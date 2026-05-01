load("@mathlib//:math_utils.star", "sqrt")

def circle_area(radius):
    return 3.14159265358979 * radius * radius

def circle_circumference(radius):
    return 2 * 3.14159265358979 * radius

def point_distance(x1, y1, x2, y2):
    dx = x2 - x1
    dy = y2 - y1
    return sqrt(dx * dx + dy * dy)
