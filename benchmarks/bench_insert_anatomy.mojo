"""Takes an insert apart, to find where the gap to the stdlib `Dict` lives.

Indexing a corpus is about 1.4x slower than a `Dict`, and "inserts are slower"
is too coarse a statement to act on. An insert is a fixed cost per map plus a
marginal cost per key, and the marginal cost is itself a steady-state part and
a share of the table growth it eventually triggers. Each is measured separately
here, because they point at different fixes:

  - a fixed cost per map is about how many allocations a constructor makes;
  - a steady-state cost is about the probe and the writes it performs;
  - a growth cost is about what `_rehash` does per entry it moves.

Run with `pixi run bench-anatomy`.
"""

from mm_string_dict import StringDict
from std.benchmark import Unit, keep, run
from std.sys import get_defined_bool

comptime ALPHABET: StaticString = "abcdefghijklmnopqrstuvwxyz0123456789"
comptime CACHING = get_defined_bool["CACHING", False]()
comptime Map = StringDict[Int, .uint32, .uint32, True, CACHING]


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.2, max_runtime_secs=2.0).mean(Unit.ns)


def fmt(value: Float64) -> String:
    var sign = "-" if value < 0 else ""
    var tenths = Int(abs(value) * 10.0 + 0.5)
    return String(sign, tenths // 10, ".", tenths % 10)


def line(label: String, ours: Float64, theirs: Float64, unit: String):
    var padded = label
    while padded.byte_length() < 30:
        padded += " "
    var a = fmt(ours)
    while a.byte_length() < 8:
        a = " " + a
    var b = fmt(theirs)
    while b.byte_length() < 8:
        b = " " + b
    print("  ", padded, a, b, " ", unit)


def random_keys(count: Int, length: Int, out result: List[String]):
    result = List[String](capacity=count)
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    for _ in range(count):
        var word = String()
        for _ in range(length):
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            word += ALPHABET[byte=Int(state & 0x7FFF_FFFF) % 36]
        result.append(word^)


def bench_fixed_cost() raises:
    """What a map costs before a single key goes into it."""

    def ours() raises:
        var map = Map()
        # `len` is a constant zero here, and keeping only that lets the
        # optimizer delete the allocations outright -- it then reports 0.3 ns.
        # Keeping the block's address forces them to happen.
        keep(Int(map.entries))

    def theirs() raises:
        var map = Dict[String, Int]()
        keep(len(map))

    print("")
    print("fixed cost per map            StringDict   stdlib")
    print("  ----------------------------------------------------")
    line("construct + destruct, empty", measure(ours), measure(theirs), "ns")
    print("")
    print("   A `StringDict` allocates three times in its constructor -- the")
    print("   key bytes, the entry block and the slot block. A `Dict`")
    print("   allocates nothing until its first insert, which is the whole of")
    print("   the difference.")


def bench_steady_state() raises:
    """Inserts with no growth and no new keys: the probe and its writes."""
    var keys = random_keys(16, 10)

    def ours() raises {imm keys}:
        var map = Map()
        for round in range(1000):
            for i in range(16):
                map.put(keys[i], round)
        keep(len(map))

    def theirs() raises {imm keys}:
        var map = Dict[String, Int]()
        for round in range(1000):
            for i in range(16):
                map[keys[i]] = round
        keep(len(map))

    print("")
    print("steady state                  StringDict   stdlib")
    print("  ----------------------------------------------------")
    line(
        "16000 puts, 16 distinct keys",
        measure(ours) / 16000.0,
        measure(theirs) / 16000.0,
        "ns per put",
    )


def bench_growth() raises:
    """Splits the marginal insert into steady-state work and table growth.

    Pre-sizing the map removes every rehash, so the difference between the two
    rows is what growth costs per insert, amortized.
    """
    comptime N = 4000
    var keys = random_keys(N, 10)

    def ours_growing() raises {imm keys}:
        var map = Map()  # 16 slots, rehashes about nine times
        for i in range(N):
            map.put(keys[i], i)
        keep(len(map))

    def ours_presized() raises {imm keys}:
        var map = Map(capacity=8192)  # never rehashes
        for i in range(N):
            map.put(keys[i], i)
        keep(len(map))

    def theirs_growing() raises {imm keys}:
        var map = Dict[String, Int]()
        for i in range(N):
            map[keys[i]] = i
        keep(len(map))

    def theirs_presized() raises {imm keys}:
        var map = Dict[String, Int](capacity=8192)
        for i in range(N):
            map[keys[i]] = i
        keep(len(map))

    def hashing() raises {imm keys}:
        var acc: UInt64 = 0
        for i in range(N):
            acc ^= hash(keys[i])
        keep(acc)

    var growing = measure(ours_growing) / N
    var presized = measure(ours_presized) / N
    var t_growing = measure(theirs_growing) / N
    var t_presized = measure(theirs_presized) / N
    var one_hash = measure(hashing) / N

    print("")
    print("4000 distinct keys            StringDict   stdlib")
    print("  ----------------------------------------------------")
    line("growing from empty", growing, t_growing, "ns per insert")
    line("pre-sized, never grows", presized, t_presized, "ns per insert")
    line(
        "so growth costs",
        growing - presized,
        t_growing - t_presized,
        "ns per insert",
    )
    print("")
    print(
        "   Doubling moves about two entries per insert, amortized, and"
        " `_rehash`"
    )
    print(
        "   recomputes each one's hash because neither the 7-bit control byte"
    )
    print("   nor the narrowed cached hash can rebuild a tag for the new")
    print(
        "   table. One hash of these keys is",
        fmt(one_hash),
        "ns, so that accounts for",
    )
    print(
        "   about",
        fmt(2.0 * one_hash),
        "ns per insert -- most of the",
        fmt((growing - presized) - (t_growing - t_presized)),
        "ns that growth costs",
    )
    print("   us over the stdlib.")


def main() raises:
    print("caching_hashes =", CACHING)
    bench_fixed_cost()
    bench_steady_state()
    bench_growth()
