"""`KeyCountType=uint16` against the default `uint32`, and both against `Dict`.

A `uint16` entry index caps the map at 65535 entries. Nothing in these corpora
comes close, and most real dictionaries -- a vocabulary, a symbol table, a set
of column names -- do not either. Narrowing it shrinks two arrays at once: the
slot index drops from 4 bytes to 2, and with it the cached hash, which is sized
from the same parameter because a rehash only needs as many hash bits as the
capacity has.

Run with `pixi run bench-narrow`.
"""

from corpora import load, names
from mm_string_dict import GROUP, StringDict
from std.benchmark import Unit, keep, run
from std.sys.info import size_of

comptime Wide = StringDict[Int, .uint32]
comptime Narrow = StringDict[Int, .uint16]


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.1, max_runtime_secs=1.5).mean(Unit.ns)


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


def wide_bytes(map: Wide) -> Int:
    return (
        map.allocated_bytes
        + Wide._entry_words(map.entry_capacity) * 8
        + map.capacity * size_of[UInt32]()
        + map.capacity
        + GROUP
    )


def narrow_bytes(map: Narrow) -> Int:
    return (
        map.allocated_bytes
        + Narrow._entry_words(map.entry_capacity) * 8
        + map.capacity * size_of[UInt16]()
        + map.capacity
        + GROUP
    )


def bench_build() raises:
    print("")
    print("index a whole corpus (microseconds)")
    print("   corpus        uint32   uint16   stdlib")
    print("   ----------------------------------------")
    for name in names():
        var words = load(name)

        def wide() raises {imm words}:
            var map = Wide()
            for i in range(len(words)):
                map.put(words[i], i)
            keep(len(map))

        def narrow() raises {imm words}:
            var map = Narrow()
            for i in range(len(words)):
                map.put(words[i], i)
            keep(len(map))

        def theirs() raises {imm words}:
            var map = Dict[String, Int]()
            for i in range(len(words)):
                map[words[i]] = i
            keep(len(map))

        print(
            "  ",
            pad(name, 12),
            rpad(fmt(measure(wide) / 1000.0), 6),
            rpad(fmt(measure(narrow) / 1000.0), 8),
            rpad(fmt(measure(theirs) / 1000.0), 8),
        )


def bench_lookup() raises:
    print("")
    print("look up every word (ns per lookup)")
    print("   corpus        uint32   uint16   stdlib")
    print("   ----------------------------------------")
    for name in names():
        var words = load(name)
        var count = Float64(len(words))
        var wide_map = Wide()
        var narrow_map = Narrow()
        var theirs_map = Dict[String, Int]()
        for i in range(len(words)):
            wide_map.put(words[i], i)
            narrow_map.put(words[i], i)
            theirs_map[words[i]] = i

        # Independently allocated probes; see bench_string_dict.mojo for why.
        var probes = List[String](capacity=len(words))
        for i in range(len(words)):
            probes.append(String(words[i], ""))

        def wide() raises {imm wide_map, imm probes}:
            var total = 0
            for i in range(len(probes)):
                total += wide_map.get(probes[i], 0)
            keep(total)

        def narrow() raises {imm narrow_map, imm probes}:
            var total = 0
            for i in range(len(probes)):
                total += narrow_map.get(probes[i], 0)
            keep(total)

        def theirs() raises {imm theirs_map, imm probes}:
            var total = 0
            for i in range(len(probes)):
                try:
                    total += theirs_map[probes[i]]
                except:
                    pass
            keep(total)

        print(
            "  ",
            pad(name, 12),
            rpad(fmt(measure(wide) / count), 6),
            rpad(fmt(measure(narrow) / count), 8),
            rpad(fmt(measure(theirs) / count), 8),
        )


def report_footprint() raises:
    print("")
    print("footprint (bytes)")
    print("   corpus        keys   uint32   uint16   saved")
    print("   ----------------------------------------------")
    var total_wide = 0
    var total_narrow = 0
    for name in names():
        var words = load(name)
        var wide_map = Wide()
        var narrow_map = Narrow()
        for i in range(len(words)):
            wide_map.put(words[i], i)
            narrow_map.put(words[i], i)
        var w = wide_bytes(wide_map)
        var n = narrow_bytes(narrow_map)
        total_wide += w
        total_narrow += n
        print(
            "  ",
            pad(name, 12),
            rpad(String(len(wide_map)), 5),
            rpad(String(w), 8),
            rpad(String(n), 8),
            rpad(String((w - n) * 100 // w) + "%", 5),
            String((w - n) // len(wide_map)) + " bytes/entry",
        )
    print(
        "   all twelve:  ",
        total_wide,
        "->",
        total_narrow,
        " saved",
        String((total_wide - total_narrow) * 100 // total_wide) + "%",
    )


def main() raises:
    print("cached hash width: uint32 index ->", size_of[Wide._HashCacheType]())
    print(
        "                   uint16 index ->", size_of[Narrow._HashCacheType]()
    )
    bench_build()
    bench_lookup()
    report_footprint()
