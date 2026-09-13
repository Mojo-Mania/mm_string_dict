"""Benchmarks `StringDict` against the stdlib `Dict[String, Int]`.

The keys are real words, not generated ones -- twelve corpora covering Latin,
Greek, Hebrew, Arabic, Georgian, Devanagari and CJK, plus a list of AWS S3
action names for long ASCII identifiers. Real keys repeat, vary in length, and
run to several bytes per character, and none of that is visible in a benchmark
built from fixed-length random strings.

Building is reported as the total time to index a whole corpus, not as a
per-word average: two of the corpora hold ten keys each, and dividing out a
constructor across ten inserts produces noise rather than a per-insert cost.
Lookups are per operation, where there is nothing fixed to amortize.

One synthetic case remains, at the end: the corpora are at most a thousand
words, so nothing else here fills a table far enough to show what probing costs
near the growth threshold.
"""

from corpora import describe, load, names
from mm_string_dict import StringDict
from std.benchmark import Unit, keep, run
from std.sys import get_defined_bool

comptime CACHING = get_defined_bool["CACHING", False]()
comptime Map = StringDict[Int, .uint32, .uint32, True, CACHING]


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)


def fmt(value: Float64) -> String:
    var tenths = Int(value * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def pad(text: String, width: Int) -> String:
    var padded = text
    while padded.byte_length() < width:
        padded += " "
    return padded^


def rpad(text: String, width: Int) -> String:
    var padded = text
    while padded.byte_length() < width:
        padded = " " + padded
    return padded^


def row(label: String, ours: Float64, theirs: Float64):
    print("  ", pad(label, 12), rpad(fmt(ours), 8), rpad(fmt(theirs), 8))


def header(title: String, unit: String):
    print("")
    print(title)
    print("   corpus     ", rpad("StringDict", 8), rpad("stdlib", 8), " ", unit)
    print("   -------------------------------------")


def bench_build(corpora: List[String]) raises:
    header("index a whole corpus", "microseconds")
    for name in corpora:
        var words = load(name)

        def ours() raises {imm words}:
            var map = Map()
            for i in range(len(words)):
                map.put(words[i], i)
            keep(len(map))

        def theirs() raises {imm words}:
            var map = Dict[String, Int]()
            for i in range(len(words)):
                map[words[i]] = i
            keep(len(map))

        row(name, measure(ours) / 1000.0, measure(theirs) / 1000.0)


def bench_word_count(corpora: List[String]) raises:
    header("count word frequencies over a whole corpus", "microseconds")
    for name in corpora:
        var words = load(name)

        def bump(value: Optional[Int]) -> Int:
            return value.value() + 1 if value else 1

        def ours() raises {imm words}:
            var map = Map()
            for i in range(len(words)):
                map.upsert(words[i], bump)
            keep(len(map))

        def theirs() raises {imm words}:
            var map = Dict[String, Int]()
            for i in range(len(words)):
                try:
                    map[words[i]] = map[words[i]] + 1
                except:
                    map[words[i]] = 1
            keep(len(map))

        row(name, measure(ours) / 1000.0, measure(theirs) / 1000.0)


def bench_lookup(corpora: List[String]) raises:
    header("look up every word, all present", "ns per lookup")
    for name in corpora:
        var words = load(name)
        var count = Float64(len(words))
        var map = Map()
        var theirs_map = Dict[String, Int]()
        for i in range(len(words)):
            map.put(words[i], i)
            theirs_map[words[i]] = i

        def ours() raises {imm map, imm words}:
            var total = 0
            for i in range(len(words)):
                total += map.get(words[i], 0)
            keep(total)

        def theirs() raises {imm theirs_map, imm words}:
            var total = 0
            for i in range(len(words)):
                try:
                    total += theirs_map[words[i]]
                except:
                    pass
            keep(total)

        row(name, measure(ours) / count, measure(theirs) / count)


def bench_absent(corpora: List[String]) raises:
    header("membership, probes from another script", "ns per lookup")
    for name in corpora:
        var words = load(name)
        # Words in a different script are absent, and their hashes are
        # uncorrelated with the stored ones.
        var probes = load("georgian" if name != "georgian" else "hindi")
        var count = Float64(len(probes))
        var map = Map()
        var theirs_map = Dict[String, Int]()
        for i in range(len(words)):
            map.put(words[i], i)
            theirs_map[words[i]] = i

        def ours() raises {imm map, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in map:
                    hits += 1
            keep(hits)

        def theirs() raises {imm theirs_map, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in theirs_map:
                    hits += 1
            keep(hits)

        row(name, measure(ours) / count, measure(theirs) / count)


def report_density(corpora: List[String]) raises:
    print("")
    print("key storage: allocated key buffer against the bytes the keys need")
    print("   corpus        keys   needed   buffer   ratio")
    print("   --------------------------------------------")
    for name in corpora:
        var words = load(name)
        var map = Map()
        for i in range(len(words)):
            map.put(words[i], i)
        var needed = 0
        for key in map.keys():
            needed += key.byte_length()
        # `key_bytes()` is the allocated buffer, so the gap is unused tail left
        # by the last growth step, not per-key overhead: the keys sit end to end
        # with no separator and no per-key header. Repeated words are stored
        # once -- english needs 1034 bytes for its 999 words.
        print(
            "  ",
            pad(name, 12),
            rpad(String(len(map)), 5),
            rpad(String(needed), 8),
            rpad(String(map.key_bytes()), 8),
            rpad(fmt(Float64(map.key_bytes()) / Float64(needed)), 7),
        )


def bench_at_high_load() raises:
    """The one synthetic case: a table filled to just under the growth point.

    The corpora are too small to reach it, and this is where probing either
    holds up or falls apart.
    """
    comptime ALPHABET: StaticString = "abcdefghijklmnopqrstuvwxyz0123456789"
    comptime FILL = 28_000  # 85% of 32768
    comptime PROBES = 4000

    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    var keys = List[String](capacity=FILL + PROBES)
    for _ in range(FILL + PROBES):
        var word = String()
        for _ in range(12):
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            word += ALPHABET[byte=Int(state & 0x7FFF_FFFF) % 36]
        keys.append(word^)

    var map = Map()
    var theirs_map = Dict[String, Int]()
    for i in range(FILL):
        map.put(keys[i], i)
        theirs_map[keys[i]] = i

    def ours() raises {imm map, imm keys}:
        var hits = 0
        for i in range(FILL, FILL + PROBES):
            if keys[i] in map:
                hits += 1
        keep(hits)

    def theirs() raises {imm theirs_map, imm keys}:
        var hits = 0
        for i in range(FILL, FILL + PROBES):
            if keys[i] in theirs_map:
                hits += 1
        keep(hits)

    header("synthetic: absent probe, table 85% full", "ns per lookup")
    row("28000 keys", measure(ours) / PROBES, measure(theirs) / PROBES)


def main() raises:
    var corpora = names()
    print("caching_hashes =", CACHING)

    print("corpora")
    for name in corpora:
        print("  ", pad(name, 12), describe(load(name)))

    bench_build(corpora)
    bench_word_count(corpora)
    bench_lookup(corpora)
    bench_absent(corpora)
    report_density(corpora)
    bench_at_high_load()
