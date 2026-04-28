load("@fizzbuzz//:fizzbuzz.star", "fizzbuzz")
load("@stringutil//:stringutil.star", "reverse", "word_count")

results = fizzbuzz(15)
for line in results:
    print(reverse(line))

sentence = "the quick brown fox jumps over the lazy dog"
print("Word count: %d" % word_count(sentence))
