# mm_string_dict

[![CI](https://github.com/Mojo-Mania/mm_string_dict/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_string_dict/actions/workflows/ci.yml)

A hash map from string keys to arbitrary values for
[Mojo](https://mojolang.org), with the keys stored compactly.

The keys do not live in individual `String`s. They are appended end to end into
one byte buffer, with a parallel array of end offsets, so a key costs its bytes
plus one offset — no per-key header, no per-key allocation. Lookups compare
against slices of that buffer.

The map itself is a Swiss table: open addressing over a power-of-two slot
array, with a **control byte** per slot holding either "empty", "deleted", or
seven bits of the key's hash. Those seven bits come from the opposite end of
the hash to the bits that choose the slot, so they are independent of it, and a
probe compares a whole group of them at once — `simd_width_of[uint8]()` slots
per instruction, which is 16 with NEON and 32 with AVX2.

```mojo
from mm_string_dict import StringDict

var counts = StringDict[Int]()
counts["apple"] = 1
counts["pear"] = 2

print(counts["apple"])          # 1, raises if absent
print(counts.get("plum", 0))    # 0, the default
print("pear" in counts)         # True
print(len(counts))              # 2

for entry in counts.items():
    print(entry.key, entry.value)
```

The surface mirrors the stdlib `Dict` where it can, so swapping one for the
other is mostly mechanical.

## Install

```bash
pixi add --git https://github.com/Mojo-Mania/mm_string_dict.git mm_string_dict
```

Needs `preview = ["pixi-build"]` in the consuming workspace and pixi 0.80+.
Or vendor the `mm_string_dict/` directory and compile with
`mojo -I path/to/mm_string_dict`.

## Usage

Counting words, with `upsert` so the key is only looked up once:

```mojo
var counts = StringDict[Int]()

def bump(value: Optional[Int]) -> Int:
    return value.value() + 1 if value else 1

for word in text.split(" "):
    counts.upsert(word, bump)
```

Four compile-time parameters trade memory for capability:

```mojo
StringDict[Int]                                       # the defaults
StringDict[Int, DType.uint16]                         # ≤65535 entries, half the slot array
StringDict[Int, DType.uint32, DType.uint16]           # ≤64KB of keys in total
StringDict[Int, DType.uint32, DType.uint32, False]    # no delete, no tombstone bitmap
StringDict[Int, DType.uint32, DType.uint32, True, True]   # cache full hashes too
```

| Parameter | Default | What it costs |
| --- | --- | --- |
| `V` | — | The value type; anything copyable. |
| `KeyCountType` | `uint32` | Indexes keys and slots, so it caps the entry count. |
| `KeyOffsetType` | `uint32` | Holds key end offsets, so it caps the **total** size of all keys. |
| `destructive` | `True` | One bit per entry for the tombstone mask. Off means `delete` does nothing. |
| `caching_hashes` | `False` | `KeyCountType` bytes per slot for a second filter after the control byte. Off by default: the tag already rejects 127 of every 128 non-matching slots, so it buys a few percent on lookups and costs the memory this container exists to save. |

## API

| Member | Meaning |
| --- | --- |
| `dict[key]` | The value, raising if the key is absent or deleted. |
| `dict[key] = value` | Insert, or replace the value if the key is there. |
| `get(key, default) -> V` | The value, or `default` when absent or deleted. |
| `key in dict`, `len(dict)`, `Bool(dict)` | Membership, entry count, emptiness. |
| `pop(key) -> V` | Remove and return, raising if absent. |
| `pop(key, default) -> V` | Remove and return, or `default`. |
| `setdefault(key, default) -> V` | The value, inserting `default` first if absent. |
| `update(other)` | Insert every live entry of `other`, replacing collisions. |
| `keys()`, `values()`, `items()`, `for key in dict` | Iterate live entries in insertion order. `values()` yields references; `items()` yields `.key` and `.value`. |
| `upsert(key, update)` | Insert or update with a function of the current value, looking the key up once. |
| `clear()` | Drop every entry, keep the storage. |
| `key_bytes()`, `print_keys()` | Inspect the packed key buffer. |

`put`, `get` and `delete` are the original names and still work; `__setitem__`,
`__getitem__` and `pop` are the `Dict`-shaped spellings of the same operations.

## Performance

Apple M-series, release build (`-D ASSERT=none`, which is what `pixi run bench`
passes), measured against the stdlib `Dict[String, Int]`.

The keys are real words. `corpora/` holds twelve word lists — Latin, Greek,
Hebrew, Arabic, Georgian, Devanagari and CJK scripts, plus a list of AWS S3
action names for long ASCII identifiers — taken from
[compact-dict](https://github.com/mzaks/compact-dict). Real keys repeat, vary
in length, and run to several bytes per character, and none of that shows up in
a benchmark built from fixed-length random strings.

| corpus | words | distinct | avg bytes | range |
| --- | --- | --- | --- | --- |
| english | 999 | 192 | 4 | 1–13 |
| german | 999 | 208 | 5 | 2–18 |
| l33t | 487 | 339 | 4 | 2–14 |
| french | 471 | 418 | 6 | 2–19 |
| greek | 452 | 320 | 10 | 3–28 |
| arabic | 463 | 336 | 9 | 2–26 |
| hebrew | 376 | 231 | 8 | 2–25 |
| hindi | 450 | 250 | 18 | 9–51 |
| georgian | 381 | 250 | 15 | 6–42 |
| s3_actions | 161 | 143 | 22 | 8–43 |
| chinese | 10 | 10 | 464 | 441–480 |
| japanese | 10 | 10 | 499 | 378–558 |

### Lookups

Nanoseconds per lookup, lower is better.

| corpus | look up every word | | membership, probe from another script | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 7.0 | **6.5** | **2.5** | 2.8 |
| german | 7.6 | **7.4** | **2.9** | 3.1 |
| l33t | **7.1** | 7.2 | **2.2** | 2.5 |
| french | 8.3 | **8.2** | **2.6** | 2.9 |
| greek | **8.2** | 8.7 | **2.3** | 2.6 |
| arabic | **9.2** | 9.4 | **2.3** | 2.6 |
| hebrew | 9.1 | **9.0** | **2.2** | 2.5 |
| hindi | **8.7** | 9.0 | **2.2** | 2.5 |
| georgian | 8.5 | **8.1** | **2.2** | 2.5 |
| s3_actions | 7.0 | **6.6** | **2.2** | 2.5 |
| chinese | 37.7 | **24.4** | **2.2** | 2.5 |
| japanese | 48.6 | **27.3** | **2.3** | 2.5 |

Present-key lookups are level with the stdlib `Dict` across every corpus with
keys of an ordinary size, and misses are consistently a little faster — the
7-bit tag in the control byte rejects a wrong key without touching the key
bytes at all.

The two CJK corpora are the exception, and the gap there grows with key length:
their "words" are whole paragraphs of 400–560 bytes, and a hit has to compare
all of them. That is a real gap, not measurement noise, and it is unexplained —
both sides bottom out in the same stdlib byte comparison. See
[`docs/improvements.md`](docs/improvements.md).

A miss with the table at 85% load is the case that used to fall apart: before
the control byte, it walked 24 slots on average and up to 468, because deleting
never freed a slot and linear probing clustered. The corpora are far too small
to reach that load, so the benchmark keeps one synthetic case for it — 28000
keys in 32768 slots, where a miss costs **3.8 ns** against the stdlib's 3.4 ns.

### Building

Microseconds to index a whole corpus, lower is better. Reported per corpus
rather than per word: two of these hold ten keys, and dividing a constructor
across ten inserts measures the constructor, not the insert.

| corpus | build a map | | count word frequencies | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 14.5 | **10.0** | **11.7** | 18.2 |
| german | 14.9 | **10.9** | **12.6** | 19.5 |
| l33t | 11.6 | **7.3** | **10.8** | 11.0 |
| french | 12.0 | **7.2** | 12.0 | **11.2** |
| greek | 11.6 | **7.5** | 11.0 | **10.9** |
| arabic | 12.0 | **7.5** | **11.2** | 11.3 |
| hebrew | 10.0 | **7.1** | **9.4** | 10.3 |
| hindi | 11.6 | **7.9** | **11.1** | 12.2 |
| georgian | 10.9 | **7.3** | **10.3** | 10.6 |
| s3_actions | 6.0 | **3.8** | 6.2 | **5.1** |
| chinese | 1.2 | **0.4** | 1.3 | **0.7** |
| japanese | 1.3 | **0.4** | 1.5 | **0.8** |

Inserting is about 1.5× slower than the stdlib `Dict`, and that is the standing
weakness. Each `put` touches four separate allocations — the packed key bytes,
the end offsets, the slot table and the values — where a `Dict` appends one
entry to one array.

Word counting is the workload where that reverses: on english and german, where
999 words collapse to about 200 distinct ones, `upsert` runs a single probe per
word and comes out 35% ahead of a `Dict`'s read-then-write pair. Where a corpus
is nearly all distinct words, the two are level and the insert cost decides.

### Memory

This is the reason to reach for the library. Keys are stored end to end in one
buffer with a parallel array of end offsets: no per-key header, no allocation
per key, and a repeated word stored once.

| corpus | distinct keys | bytes of keys | key buffer |
| --- | --- | --- | --- |
| english | 192 | 1034 | 1458 |
| german | 208 | 1359 | 1458 |
| s3_actions | 143 | 3233 | 3280 |
| hindi | 250 | 4555 | 4920 |
| japanese | 10 | 4992 | 7380 |

The buffer runs 1.0–1.5× the bytes the keys need, and the excess is unused tail
from the last growth step, not per-key overhead. A `Dict[String, Int]` instead
stores a `String` per entry: 24 bytes of header each before any of its bytes,
and a separate allocation once a key outgrows the inline buffer. The slot table
costs 5 bytes per slot (1 control byte + 4 index), down from 8 before the
control byte replaced the cached hash.

## Development

```bash
pixi run test     # the test suite (47 tests)
pixi run bench    # the benchmarks above
pixi run main     # the example
pixi run format   # mojo format
pixi run docs     # docstring check
pixi build        # build the conda package (needs pixi >= 0.80)
```

## Provenance

This is Maxim Zaks' `StringDict`, which also lives in the Mojo standard
library's benchmark suite. Packaged here as a library, with tests, benchmarks,
a `Dict`-shaped API, and three bug fixes — see
[`docs/fixes.md`](docs/fixes.md).

The word lists in `corpora/` come from
[mzaks/compact-dict](https://github.com/mzaks/compact-dict), where this
implementation started.

## License

MIT. See [LICENSE](LICENSE).
