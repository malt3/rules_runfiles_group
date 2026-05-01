load("@colors//:colors.star", "BLUE", "GREEN", "RED")
load("@limits//:limits.star", "MAX_INT", "MIN_INT")
load("@mathlib//:constants.star", "E", "PI")
load("@mathlib//arithmetic:add.star", "sum_list")
load("@mathlib//arithmetic:multiply.star", "factorial", "power")
load("@mathlib//geometry:circle.star", "circle_area", "circle_circumference")
load("@mathlib//geometry/shapes:rectangle.star", "rectangle_area", "rectangle_perimeter")
load("@templates//:css.star", "color", "reset_css")
load("@templates//:html.star", "document", "heading", "list_items", "paragraph", "table")
load("@units//:units.star", "CM_PER_INCH", "KG_PER_LB")

print("=== Math Demo ===")
print("PI = %s, E = %s" % (PI, E))
print("sum([1,2,3,4,5]) = %d" % sum_list([1, 2, 3, 4, 5]))
print("5! = %d" % factorial(5))
print("2^10 = %d" % power(2, 10))
print("circle area (r=5) = %s" % circle_area(5))
print("circle circumference (r=5) = %s" % circle_circumference(5))
print("rectangle area (3x4) = %d" % rectangle_area(3, 4))
print("rectangle perimeter (3x4) = %d" % rectangle_perimeter(3, 4))

print("\n=== Constants ===")
print("Colors: %s, %s, %s" % (RED, GREEN, BLUE))
print("1 inch = %s cm" % CM_PER_INCH)
print("1 lb = %s kg" % KG_PER_LB)
print("int range: [%d, %d]" % (MIN_INT, MAX_INT))

print("\n=== Template Demo ===")
print(reset_css())
print(color("coral"))
html = document("Demo", "\n".join([
    heading(1, "Merge Test"),
    paragraph("Testing runfiles group merging with many deps."),
    list_items(["mathlib", "templates", "colors", "units", "limits"]),
    table(
        ["Library", "Type"],
        [
            ["mathlib", "large nested"],
            ["templates", "large flat"],
            ["colors", "tiny constants"],
            ["units", "tiny constants"],
            ["limits", "tiny constants"],
        ],
    ),
]))
print(html)
