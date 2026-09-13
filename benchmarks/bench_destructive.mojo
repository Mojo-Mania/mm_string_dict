"""Measures what the `destructive` parameter costs when it is left on.

`destructive=True` (the default) buys `delete`, `pop` and `clear`. It pays for
them with one bit per entry in a tombstone mask, the allocation that holds it,
and a call on the insert path to keep that mask large enough.

Run one variant per process -- an allocator warmed by one variant moves the
other's build figures by a few nanoseconds:

    pixi run bench-destructive       # destructive=True
    pixi run bench-non-destructive   # destructive=False

Reads are expected to be identical. A tombstoned slot is excluded from a lookup
by its control byte, which no longer matches any 7-bit tag, so the mask is
never consulted while probing; it exists for iteration, which walks entries
rather than slots.
"""

from corpora import load, names
from mm_string_dict import GROUP, StringDict
from std.benchmark import Unit, keep, run
from std.sys import get_defined_bool
from std.sys.info import size_of

comptime DESTRUCTIVE = get_defined_bool["DESTRUCTIVE", True]()
comptime Map = StringDict[Int, destructive=DESTRUCTIVE]


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


def footprint(map: Map) -> Int:
    """Every byte the map has allocated, mask included."""
    comptime INDEX = size_of[Scalar[Map.KeyCountType]]()
    comptime OFFSET = size_of[Scalar[Map.KeyOffsetType]]()
    var total = map._keys.allocated_bytes  # packed key bytes
    total += map._keys.capacity * OFFSET  # end offsets
    total += map.capacity + GROUP  # control bytes plus mirror
    total += map.capacity * INDEX  # slot -> entry index
    # Values, cached hashes and the tombstone mask share one entry block.
    total += Map._entry_words(map.entry_capacity) * size_of[UInt64]()
    return total


def build(words: List[String], out result: Map):
    result = Map()
    for i in range(len(words)):
        result.put(words[i], i)


def bench_corpora() raises:
    print("")
    print("index a whole corpus (microseconds) and its footprint (bytes)")
    print("   corpus        build    bytes   mask")
    print("   ---------------------------------------")
    for name in names():
        var words = load(name)

        def ours() raises {imm words}:
            var map = build(words)
            keep(len(map))

        var map = build(words)
        var mask = 0
        comptime if Map.destructive:
            mask = (map.entry_capacity + 7) >> 3
        print(
            "  ",
            pad(name, 12),
            rpad(fmt(measure(ours) / 1000.0), 7),
            rpad(String(footprint(map)), 8),
            rpad(String(mask), 6),
        )


def bench_reads() raises:
    print("")
    print("reads over every corpus (ns per lookup)")
    print("   corpus        hit     miss")
    print("   -------------------------------")
    for name in names():
        var words = load(name)
        var probes = load("georgian" if name != "georgian" else "hindi")
        var map = build(words)

        def hit() raises {imm map, imm words}:
            var total = 0
            for i in range(len(words)):
                total += map.get(words[i], 0)
            keep(total)

        def miss() raises {imm map, imm probes}:
            var hits = 0
            for i in range(len(probes)):
                if probes[i] in map:
                    hits += 1
            keep(hits)

        print(
            "  ",
            pad(name, 12),
            rpad(fmt(measure(hit) / Float64(len(words))), 6),
            rpad(fmt(measure(miss) / Float64(len(probes))), 7),
        )


def bench_at_scale() raises:
    """28000 keys, where the tombstone mask actually has to grow.

    Every corpus fits in the mask's first allocation, so none of them exercises
    the growth call that `put` makes on each insert.
    """
    comptime ALPHABET: StaticString = "abcdefghijklmnopqrstuvwxyz0123456789"
    comptime FILL = 28_000
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

    def insert() raises {imm keys}:
        var map = Map()
        for i in range(FILL):
            map.put(keys[i], i)
        keep(len(map))

    var map = Map()
    for i in range(FILL):
        map.put(keys[i], i)

    def hit() raises {imm map, imm keys}:
        var total = 0
        for i in range(FILL - PROBES, FILL):
            total += map.get(keys[i], 0)
        keep(total)

    def miss() raises {imm map, imm keys}:
        var hits = 0
        for i in range(FILL, FILL + PROBES):
            if keys[i] in map:
                hits += 1
        keep(hits)

    print("")
    print("28000 twelve-byte keys")
    print("   build          ", fmt(measure(insert) / 1000.0), "us")
    print("   insert         ", fmt(measure(insert) / Float64(FILL)), "ns")
    print("   hit            ", fmt(measure(hit) / Float64(PROBES)), "ns")
    print("   miss           ", fmt(measure(miss) / Float64(PROBES)), "ns")
    print("   footprint      ", footprint(map), "bytes")
    comptime if Map.destructive:
        print("   tombstone mask ", (map.entry_capacity + 7) >> 3, "bytes")


def main() raises:
    print("destructive =", DESTRUCTIVE, " group width =", GROUP)
    bench_corpora()
    bench_reads()
    bench_at_scale()
