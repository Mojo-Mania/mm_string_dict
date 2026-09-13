"""Benchmarks `StringDict` against the stdlib `Dict[String, Int]`.

The difference is where the keys live. `Dict` stores a `String` per entry, each
with its own heap allocation once it outgrows the inline buffer; `StringDict`
appends every key into one byte buffer and keeps an end offset per key. That
should show up on build time and on memory, and cost nothing on lookup.

Every number is nanoseconds per operation. Lower is better. The keys come from
a fixed seed, so runs are comparable.

One caveat: these all run in one process, and a benchmark's allocator state
carries into the next, which moves the build figures by a few nanoseconds. The
build numbers quoted in the README were taken one variant per process.
"""

from mm_string_dict import StringDict
from std.benchmark import Unit, keep, run


comptime SIZE = 20_000
"""Entries per map."""


struct Rng(Copyable, Movable):
    """A xorshift64 generator, so every run sees the same keys."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Int:
        self.state ^= self.state << 13
        self.state ^= self.state >> 7
        self.state ^= self.state << 17
        return Int(self.state & 0x7FFF_FFFF)


comptime _ALPHABET: StaticString = "abcdefghijklmnopqrstuvwxyz0123456789"


def random_keys(
    count: Int, length: Int = 12, seed: UInt64 = 0x2545_F491_4F6C_DD1D
) -> List[String]:
    var rng = Rng(seed)
    var result = List[String](capacity=count)
    for _ in range(count):
        var value = String()
        for _ in range(length):
            value += _ALPHABET[byte=rng.next() % 36]
        result.append(value^)
    return result^


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)


def fmt(nanos: Float64) -> String:
    var tenths = Int(nanos * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def header(title: String):
    print("")
    print(title)
    print("  container            ns/op")
    print("  ---------------------------")


def report(name: String, nanos: Float64):
    var padded = name
    while padded.byte_length() < 20:
        padded += " "
    print("  ", padded, fmt(nanos))


def per_op(total_ns: Float64, operations: Int) -> Float64:
    return total_ns / Float64(operations)


def bench_build(title: String, keys: List[String]) raises:
    header(title)
    var count = len(keys)

    def build_dict() raises {imm keys}:
        var map = StringDict[Int]()
        for i in range(len(keys)):
            map.put(keys[i], i)
        keep(len(map))

    def build_stdlib() raises {imm keys}:
        var map = Dict[String, Int]()
        for i in range(len(keys)):
            map[keys[i]] = i
        keep(len(map))

    report("StringDict", per_op(measure(build_dict), count))
    report("stdlib Dict", per_op(measure(build_stdlib), count))


def bench_lookup(
    title: String, keys: List[String], probes: List[String]
) raises:
    header(title)
    var count = len(probes)

    var map = StringDict[Int]()
    var stdlib = Dict[String, Int]()
    for i in range(len(keys)):
        map.put(keys[i], i)
        stdlib[keys[i]] = i

    def probe_dict() raises {imm map, imm probes}:
        var total = 0
        for i in range(len(probes)):
            total += map.get(probes[i], 0)
        keep(total)

    def probe_stdlib() raises {imm stdlib, imm probes}:
        var total = 0
        for i in range(len(probes)):
            try:
                total += stdlib[probes[i]]
            except:
                pass
        keep(total)

    report("StringDict", per_op(measure(probe_dict), count))
    report("stdlib Dict", per_op(measure(probe_stdlib), count))


def bench_contains(keys: List[String], probes: List[String]) raises:
    header("membership, no probe present (per lookup)")
    var count = len(probes)

    var map = StringDict[Int]()
    var stdlib = Dict[String, Int]()
    for i in range(len(keys)):
        map.put(keys[i], i)
        stdlib[keys[i]] = i

    def probe_dict() raises {imm map, imm probes}:
        var hits = 0
        for i in range(len(probes)):
            if probes[i] in map:
                hits += 1
        keep(hits)

    def probe_stdlib() raises {imm stdlib, imm probes}:
        var hits = 0
        for i in range(len(probes)):
            if probes[i] in stdlib:
                hits += 1
        keep(hits)

    report("StringDict", per_op(measure(probe_dict), count))
    report("stdlib Dict", per_op(measure(probe_stdlib), count))


def report_memory(keys: List[String]) raises:
    var map = StringDict[Int]()
    for i in range(len(keys)):
        map.put(keys[i], i)
    var key_bytes = 0
    for i in range(len(keys)):
        key_bytes += keys[i].byte_length()
    print("")
    print("memory for", len(keys), "keys of 12 bytes")
    print(
        "   StringDict         ",
        map.key_bytes(),
        "bytes of key storage,",
        map.capacity,
        "slots",
    )
    print("   the keys themselves", key_bytes, "bytes")
    print(
        "   stdlib Dict         one String header per entry, plus its"
        " allocation"
    )


def bench_at_high_load(keys: List[String], misses: List[String]) raises:
    """The same lookups with the table nearly full.

    The default benchmark sits at 61% load, because the table doubles at 87.5%
    and had just done so. Probe chains are short there. This fills a table to
    just under the threshold, which is where probing actually costs something.
    """
    comptime FILL = 28_000  # 85% of 32768
    header("lookup at 85% load (per lookup)")

    var map = StringDict[Int]()
    var stdlib = Dict[String, Int]()
    for i in range(FILL):
        map.put(keys[i], i)
        stdlib[keys[i]] = i

    var probes = List[String](capacity=4000)
    for i in range(4000):
        probes.append(misses[i])
    var count = len(probes)

    def miss_dict() raises {imm map, imm probes}:
        var hits = 0
        for i in range(len(probes)):
            if probes[i] in map:
                hits += 1
        keep(hits)

    def miss_stdlib() raises {imm stdlib, imm probes}:
        var hits = 0
        for i in range(len(probes)):
            if probes[i] in stdlib:
                hits += 1
        keep(hits)

    def hit_dict() raises {imm map, imm keys}:
        var total = 0
        for i in range(4000):
            total += map.get(keys[i], 0)
        keep(total)

    report("StringDict, miss", per_op(measure(miss_dict), count))
    report("stdlib Dict, miss", per_op(measure(miss_stdlib), count))
    report("StringDict, hit", per_op(measure(hit_dict), 4000))


def main() raises:
    print("StringDict benchmarks --", SIZE, "entries, ns per operation")
    var keys = random_keys(SIZE)
    var misses = random_keys(SIZE, seed=0xDEAD_BEEF_CAFE_F00D)

    bench_build("build from random keys (per insert)", keys)
    bench_lookup("lookup, every probe present (per lookup)", keys, keys)
    bench_contains(keys, misses)
    bench_at_high_load(
        random_keys(30_000), random_keys(30_000, seed=0x1234_5678)
    )

    var long_keys = random_keys(SIZE, length=64)
    bench_build("build from 64-byte keys (per insert)", long_keys)

    report_memory(keys)
