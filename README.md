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
| english | 6.6 | **6.5** | **2.5** | 2.8 |
| german | 7.8 | **7.5** | **2.9** | 3.0 |
| l33t | 7.9 | **7.2** | **2.2** | 2.5 |
| french | 8.4 | 8.4 | **2.6** | 2.9 |
| greek | 9.0 | **8.7** | **2.3** | 2.7 |
| arabic | **9.3** | 9.7 | **2.3** | 2.6 |
| hebrew | **9.5** | 9.6 | **2.2** | 2.5 |
| hindi | **8.8** | 9.1 | **2.2** | 2.5 |
| georgian | 8.4 | 8.4 | **2.2** | 2.5 |
| s3_actions | 6.7 | 6.7 | **2.2** | 2.5 |
| chinese | 40.4 | **24.4** | **2.3** | 2.5 |
| japanese | 51.2 | **27.5** | **2.3** | 2.5 |

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
| english | 14.5 | **9.9** | **11.0** | 18.5 |
| german | 14.4 | **10.9** | **11.9** | 19.7 |
| l33t | 10.3 | **7.4** | **9.3** | 11.0 |
| french | 10.4 | **7.4** | **10.4** | 11.2 |
| greek | 10.5 | **7.5** | **10.1** | 11.1 |
| arabic | 10.5 | **7.5** | **10.1** | 11.1 |
| hebrew | 9.1 | **7.1** | **8.6** | 10.4 |
| hindi | 10.6 | **7.8** | **10.0** | 12.1 |
| georgian | 9.9 | **7.3** | **9.5** | 10.6 |
| s3_actions | 5.4 | **3.8** | 5.6 | **5.3** |
| chinese | 1.1 | **0.4** | 1.3 | **0.7** |
| japanese | 1.2 | **0.5** | 1.5 | **0.8** |

Inserting is about 1.4× slower than the stdlib `Dict`, and that is the standing
weakness — but not where it looks. Taking an insert apart
(`pixi run bench-anatomy`), a steady-state `put` is already even at 10.8 ns
against 11.8, and inserting into a pre-sized map is within 4%. The whole gap is
table growth, which costs 12.3 ns per insert here against the stdlib's 9.0, and
most of that difference is `_rehash` recomputing a hash for every entry it moves
where the stdlib reuses a stored one. If you know the size up front, passing
`StringDict[Int](capacity=n)` removes it.

Word counting is where that reverses, and it now does so on ten of the twelve
corpora. `upsert` settles a word in one probe against a `Dict`'s read-then-write
pair, which is worth 40% on english and german — 999 words collapsing to about
200 distinct ones, so almost every word is an update — and 5–20% elsewhere.
Only the two CJK corpora and s3_actions, where nearly every word is distinct and
the insert cost decides, come out behind.

### Deletion support is close to free

`destructive` is on by default; turning it off removes `delete`, `pop` and
`clear`, and with them one bit per entry. Measured one variant per process
(`pixi run bench-destructive` and `pixi run bench-non-destructive`), at 28000
twelve-byte keys:

| | destructive=True | destructive=False |
| --- | --- | --- |
| insert | 19.8 ns | 20.2 ns |
| lookup, hit | 17.4 ns | 17.8 ns |
| lookup, miss | 3.7 ns | 3.8 ns |
| footprint | 995909 bytes | 991813 bytes |

Reads are unaffected by design: a tombstoned slot is excluded from a lookup by
its control byte, which no longer matches any 7-bit tag, so probing never
consults the mask. The mask exists for iteration, which walks entries rather
than slots.

Inserts used to pay 19% for deletion support. That was not the bit — it was the
mask's bounds check sitting behind a `@no_inline` call, so every insert paid for
a call to learn the mask was already big enough. With the check hoisted into the
caller, the two variants are level and the only remaining cost is the 4096 bytes
of mask, 0.4% of the map.

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
pixi run test     # the test suite (48 tests)
pixi run bench    # the benchmarks above
pixi run bench-destructive      # the destructive=True variant, alone
pixi run bench-non-destructive  # the destructive=False variant, alone
pixi run bench-anatomy          # where an insert's time actually goes
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
