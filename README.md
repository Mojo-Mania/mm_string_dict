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

## When to use it

**It halves the memory.** Across twelve real word lists a `StringDict` takes
**52% of what `Dict[String, Int]` takes** — 20–31 bytes of overhead per entry
against 48–90. A stdlib slot is 40 bytes before any key data (an 8-byte hash, a
24-byte `String`, an 8-byte value), and a key longer than 23 bytes gets a heap
allocation of its own on top. Here a key costs its bytes, four bytes of end
offset, and nothing else.

**Reach for it when:**

- You hold a lot of string keys and the footprint matters — a symbol table, an
  inverted index, a vocabulary, a lookup table read far more often than written.
- You build many small maps: one per document, per request, per group. That is
  where it wins outright, **519 ns per 20-word document against the stdlib's
  813**, and it wins at every size measured.
- Your workload is read-mostly, or counts things. Lookups are level with the
  stdlib and `upsert` beats it on ten of twelve corpora, english by 68%.
- You know the size up front. `StringDict[Int](capacity=n)` removes the growth
  that is the whole of the remaining insert gap.

**Look elsewhere when:**

- Your keys are not strings. This is string-keyed only, by construction.
- Your keys are huge *and few*. At 400–560 bytes per key the memory advantage
  disappears (98–135% of `Dict`), because the stdlib's 40-byte slot is noise
  beside the key itself. Lookups stay level.
- You re-probe with the same `String` objects you inserted. A `Dict` stores an
  alias of your string (Mojo's `String` is copy-on-write) and compares on
  pointer identity, which a packed buffer cannot match — worth 2× on very long
  keys.
- You churn heavily. A deleted entry's key bytes and value are held until the
  map is dropped, because entries are never renumbered, so a long-lived map
  under constant insert/delete grows in key storage even as the table does not.
- You insert into one big map and do little else. Building is still ~1.3× the
  stdlib's, all of it in table growth.

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

Apple M-series, release build (`-D ASSERT=none`, which is what the `bench` tasks
pass), against the stdlib `Dict[String, Int]`.

The keys are real words. `corpora/` holds twelve word lists — Latin, Greek,
Hebrew, Arabic, Georgian, Devanagari and CJK scripts, plus a list of AWS S3
action names for long ASCII identifiers — taken from
[compact-dict](https://github.com/mzaks/compact-dict). Real keys repeat, vary in
length, and run to several bytes per character, and none of that shows up in a
benchmark built from fixed-length random strings.

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

### Memory

The headline. Bytes for a map holding every distinct word of a corpus, counting
every allocation each container makes.

| corpus | keys | bytes of keys | StringDict | stdlib Dict | ratio | overhead/entry |
| --- | --- | --- | --- | --- | --- | --- |
| english | 192 | 1034 | **5203** | 11536 | 45% | 21 vs 54 |
| german | 208 | 1359 | **6427** | 11536 | 55% | 24 vs 48 |
| l33t | 339 | 1685 | **10277** | 23056 | 44% | 25 vs 63 |
| french | 418 | 2809 | **11384** | 23056 | 49% | 20 vs 48 |
| greek | 320 | 3641 | **13045** | 23211 | 56% | 29 vs 61 |
| arabic | 336 | 3338 | **13045** | 23082 | 56% | 28 vs 58 |
| hebrew | 231 | 2334 | **9552** | 23153 | 41% | 31 vs 90 |
| hindi | 250 | 4555 | **11213** | 24386 | 45% | 26 vs 79 |
| georgian | 250 | 4558 | **11213** | 25364 | 44% | 26 vs 83 |
| s3_actions | 143 | 3233 | **7048** | 13353 | 52% | 26 vs 70 |
| chinese | 10 | 4647 | **5277** | 5383 | 98% | 63 vs 73 |
| japanese | 10 | 4992 | 7768 | **5728** | 135% | 277 vs 73 |
| **all twelve** | | | **111452** | 212844 | **52%** | |

`size_of[String]` is 24 bytes, so a stdlib slot is 40 before any key data, and
Mojo's inline string buffer runs out at 23 bytes — past that each key is a
separate allocation. A `StringDict` entry costs its key bytes plus four bytes of
end offset, eight of value, one bit of tombstone, and five bytes in the slot
table.

The two CJK rows are where this stops paying: at ~500 bytes per key the stdlib's
per-entry overhead is noise, and with only ten keys the growth overshoot in the
key buffer is not amortized. A map of a hundred such keys would land back near
parity.

A map makes three allocations, split by what makes each one grow — the key bytes
when the bytes run out, the entry block (end offsets, hashes, values, tombstones)
when the entry count does, and the slot table at 7/8 load.

### Lookups

Nanoseconds per lookup.

| corpus | every word, present | | probe from another script | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 6.7 | **6.4** | **2.6** | 2.8 |
| german | 7.7 | 7.7 | **3.0** | 3.2 |
| l33t | 7.7 | **7.6** | **2.3** | 2.5 |
| french | **8.4** | 8.5 | **2.7** | 2.9 |
| greek | **8.8** | 8.9 | **2.4** | 2.7 |
| arabic | **9.5** | 9.6 | **2.4** | 2.6 |
| hebrew | **9.2** | 9.6 | **2.3** | 2.5 |
| hindi | **8.7** | 9.2 | **2.3** | 2.6 |
| georgian | **8.5** | 8.7 | **2.3** | 2.5 |
| s3_actions | **6.7** | 7.1 | **2.3** | 2.5 |
| chinese | **38.8** | 50.7 | **2.3** | 2.6 |
| japanese | 56.8 | **54.3** | **2.3** | 2.5 |

Level on every corpus, and misses are consistently a little faster — the 7-bit
tag in the control byte rejects a wrong key without touching the key bytes at
all. On the 464-byte Chinese keys the packed buffer pulls ahead by 24%.

**A note on how these are measured, because it changes the answer.** Mojo's
`String` is copy-on-write: `d[key] = v` on a `Dict[String, V]` stores a key that
*shares its buffer* with the string you passed — verified, ten of ten stored keys
aliasing the inserted object. Probe with that same object and `String.__eq__`
answers on pointer identity without reading a byte. This benchmark used to do
exactly that, and it made the stdlib look twice as fast on long keys: 27.6 ns
against 52.3 for the same lookup with an equal but independently allocated
probe. A `StringDict` copies keys into its packed buffer, so it can never take
that path, and comparing the two that way measured the copy-on-write rather than
the maps. The table above probes both with fresh strings.

Which is the honest default: you usually look up a key you built or received,
not the identical object you inserted. If your workload really does re-probe
with the same `String` objects, a `Dict` has a genuine edge on long keys that a
packed buffer cannot match.

A miss with the table 85% full — the case that used to fall apart, walking 24
slots on average before the control byte existed — costs **3.8 ns** against the
stdlib's 3.4. The corpora are far too small to reach that load, so the benchmark
keeps one synthetic case for it.

### Building

Microseconds for a whole corpus. Reported per corpus rather than per word: two
of these hold ten keys, and dividing a constructor across ten inserts measures
the constructor.

| corpus | index every word | | count word frequencies | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 12.9 | **10.2** | **10.0** | 18.3 |
| german | 13.1 | **11.0** | **10.8** | 20.3 |
| l33t | 9.2 | **7.4** | **8.8** | 11.2 |
| french | 9.9 | **7.4** | **9.5** | 11.3 |
| greek | 10.1 | **7.7** | **9.0** | 11.0 |
| arabic | 9.6 | **7.7** | **9.3** | 11.2 |
| hebrew | 8.3 | **7.4** | **7.8** | 10.5 |
| hindi | 9.5 | **7.9** | **8.8** | 12.2 |
| georgian | 9.0 | **7.4** | **8.5** | 10.5 |
| s3_actions | 4.7 | **3.9** | 4.7 | **5.3** |
| chinese | 0.9 | **0.4** | 1.1 | **0.7** |
| japanese | 1.0 | **0.5** | 1.3 | **0.8** |

Indexing is about 1.3× the stdlib, and part of that is inherent: a `StringDict`
copies each key's bytes into its packed buffer, where a `Dict` stores a
copy-on-write alias and copies nothing. That is the price of the density, and it
shows most on the CJK rows, where the stdlib gets 500 bytes per key for free. It
also means the source strings can be dropped once the map is built — a `Dict`
keeps every one of their allocations alive.

Counting — the same work plus a read per word — is *faster* on ten of twelve
corpora, because `upsert` settles a word in one probe where a `Dict` needs a read
and then a write. On english that is 83%.

### Many small maps

One map per document, which is the shape of a term-frequency or grouping pass.
Nanoseconds per document.

| document | StringDict | stdlib |
| --- | --- | --- |
| 5 words | **176** | 205 |
| 20 words | **526** | 841 |
| 100 words | **2017** | 2865 |

### Where an insert's time goes

`pixi run bench-anatomy` splits an insert into a fixed cost per map, a
steady-state cost, and a share of the growth it eventually triggers.

| | StringDict | stdlib |
| --- | --- | --- |
| construct + destruct, empty | 38.5 ns | 0.3 ns |
| put, steady state | **10.5 ns** | 12.2 ns |
| insert, 4000 keys, pre-sized | 11.4 ns | 11.2 ns |
| insert, 4000 keys, growing from empty | 22.9 ns | 20.0 ns |
| → so growth costs | 11.6 ns | 8.7 ns |

Steady state is ahead, and pre-sized the two are level. The whole of the gap is
table growth, which is more than half of an insert for both. The stdlib `Dict`
constructs for nothing because it allocates lazily; that suits a type used for
empty dictionaries everywhere, which this one is not.

### Tuning

| parameter | default | what it buys |
| --- | --- | --- |
| `capacity=n` | 16 | Removes growth, which is the entire insert gap. |
| `destructive` | `True` | `delete`/`pop`/`clear`, for one bit per entry and no measurable time. |
| `caching_hashes` | `False` | A rehash reuses stored hashes instead of recomputing: growth 12.3 → 10.9 ns, 4–7% off a build. Costs 8 bytes per entry, 19–34% of a map. Does not change lookups. |
| `KeyCountType` | `uint32` | Narrower shrinks the slot table; `put` aborts if entries exceed what it can index. |
| `KeyOffsetType` | `uint32` | Caps the total size of all keys together. |

## Development

```bash
pixi run test                   # the test suite (54 tests)
pixi run main                   # the example
pixi run format                 # mojo format
pixi run docs                   # docstring check
pixi build                      # the conda package (needs pixi >= 0.80)

pixi run bench                  # the corpus tables above
pixi run bench-small-maps       # one map per document
pixi run bench-anatomy          # where an insert's time goes
pixi run bench-destructive      # destructive=True, one variant per process
pixi run bench-non-destructive  # destructive=False, likewise
pixi run bench-cached           # the corpus tables with caching_hashes on
pixi run bench-anatomy-cached   # the anatomy with caching_hashes on
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
