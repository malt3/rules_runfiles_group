def sqrt(x):
    if x < 0:
        fail("sqrt of negative number")
    if x == 0:
        return 0
    guess = x / 2
    for _ in range(50):
        guess = (guess + x / guess) / 2
    return guess
