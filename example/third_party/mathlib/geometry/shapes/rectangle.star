load("@mathlib//:math_utils.star", "sqrt")

def rectangle_area(width, height):
    return width * height

def rectangle_perimeter(width, height):
    return 2 * (width + height)

def square_area(side):
    return side * side

def square_perimeter(side):
    return 4 * side

def is_square(width, height):
    return width == height

def scale_rectangle(width, height, factor):
    return (width * factor, height * factor)

def rectangle_diagonal(width, height):
    return sqrt(width * width + height * height)
