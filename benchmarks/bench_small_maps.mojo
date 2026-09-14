"""Many small maps, which is a shape this container meets often.

A term-frequency pass, a grouping step, or an inverted index builds one map per
document rather than one map for the corpus. Those maps are small and
short-lived, so what they cost is mostly what a constructor costs -- a very
different question from how fast a large map inserts.

The documents here are slices of the english corpus, which repeats words the
way real text does.

A hundred-word document holds at most a hundred distinct keys, so the entry
index can be as narrow as `uint8`, and the cached hash narrows with it. Whether
the cache earns its place at all is a fair question at this size -- a map of
twenty entries rehashes twice, so there is very little hashing for it to save.
Both are selectable here, one configuration per process:

    pixi run bench-small-maps          # uint32 index, cache on (the default)
    pixi run bench-small-maps-8        # uint8 index, cache on
    pixi run bench-small-maps-8-plain  # uint8 index, cache off
"""

from corpora import load
from mm_string_dict import GROUP, StringDict
from std.benchmark import Unit, keep, run
from std.sys import get_defined_bool, get_defined_int
from std.sys.info import size_of

comptime INDEX_BITS = get_defined_int["INDEX", 32]()
comptime CACHE = get_defined_bool["CACHE", True]()
comptime INDEX = (
    DType.uint8 if INDEX_BITS
    == 8 else (DType.uint16 if INDEX_BITS == 16 else DType.uint32)
)
comptime Map = StringDict[Int, INDEX, .uint32, True, CACHE]


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
    print(
        "KeyCountType = uint",
        INDEX_BITS,
        " caching_hashes =",
        CACHE,
        " cached hash =",
        size_of[Map._HashCacheType]() if CACHE else 0,
        "bytes",
    )
    print("count word frequencies, one map per document")
    print("   document    StringDict   stdlib   ns per document")
    print("   ------------------------------------------------")
    for doc_len in [5, 20, 100]:
        var docs = len(words) // doc_len

        def ours() raises {imm words, imm doc_len, imm docs}:
            var total = 0
            for d in range(docs):
                var map = Map()
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

    # Exact, so it needs no per-process care.
    print("")
    print("   footprint of one document's map (bytes)")
    for doc_len in [5, 20, 100]:
        var map = Map()
        for i in range(doc_len):
            map.put(words[i], i)
        var bytes = map.allocated_bytes
        bytes += Map._entry_words(map.entry_capacity) * 8
        bytes += map.capacity * size_of[Scalar[INDEX]]() + map.capacity + GROUP
        var theirs = Dict[String, Int]()
        for i in range(doc_len):
            theirs[words[i]] = i
        print(
            "  ",
            doc_len,
            "words ->",
            len(map),
            "keys,",
            bytes,
            "bytes",
        )
