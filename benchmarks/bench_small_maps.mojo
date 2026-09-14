"""Many small maps, which is a shape this container meets often.

A term-frequency pass, a grouping step, or an inverted index builds one map per
document rather than one map for the corpus. Those maps are small and
short-lived, so what they cost is mostly what a constructor costs -- a very
different question from how fast a large map inserts.

The documents here are slices of the english corpus, which repeats words the
way real text does.
"""

from corpora import load
from mm_string_dict import StringDict
from std.benchmark import Unit, keep, run


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.3, max_runtime_secs=2.5).mean(Unit.ns)


def fmt(value: Float64) -> String:
    var tenths = Int(value * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def main() raises:
    var words = load("english")

    def bump(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    print("")
    print("count word frequencies, one map per document")
    print("   document    StringDict   stdlib   ns per document")
    print("   ------------------------------------------------")
    for doc_len in [5, 20, 100]:
        var docs = len(words) // doc_len

        def ours() raises {imm words, imm doc_len, imm docs}:
            var total = 0
            for d in range(docs):
                var map = StringDict[Int]()
                for i in range(d * doc_len, (d + 1) * doc_len):
                    map.upsert(words[i], bump)
                total += len(map)
            keep(total)

        def theirs() raises {imm words, imm doc_len, imm docs}:
            var total = 0
            for d in range(docs):
                var map = Dict[String, Int]()
                for i in range(d * doc_len, (d + 1) * doc_len):
                    try:
                        map[words[i]] = map[words[i]] + 1
                    except:
                        map[words[i]] = 1
                total += len(map)
            keep(total)

        var label = String(doc_len, " words")
        while label.byte_length() < 12:
            label += " "
        print(
            "  ",
            label,
            fmt(measure(ours) / Float64(docs)),
            "   ",
            fmt(measure(theirs) / Float64(docs)),
        )
