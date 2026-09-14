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
per instruction, capped at 32: 16 with NEON, 32 with AVX2 and AVX-512.

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

**It roughly halves the memory.** Across twelve real word lists a `StringDict`
takes **59% of what `Dict[String, Int]` takes** with the defaults, and **51%**
as `StringDict[Int, .uint16]` if the map will hold fewer than 65535 keys — which
costs nothing in speed, so prefer it when you can. A
stdlib slot is 40 bytes before any key data (an 8-byte hash, a 24-byte `String`,
an 8-byte value), and a key longer than 23 bytes gets a heap allocation of its
own on top. Here a key costs its bytes, four bytes of end offset, four of cached
hash, and nothing else.

The timings below are from Apple silicon. On x86-64 with AVX-512 the memory
figures hold, but lookups and builds trail the stdlib — see
*Linux x86-64 (AVX-512)*.

**Reach for it when:**

- You hold a lot of string keys and the footprint matters — a symbol table, an
  inverted index, a vocabulary, a lookup table read far more often than written.
- You build many small maps: one per document, per request, per group. That is
  where it wins outright, **573 ns per 20-word document against the stdlib's
  851**, and it wins at every size measured.
- Your workload is read-mostly, or counts things. Lookups are level with the
  stdlib and `upsert` beats it on ten of twelve corpora, english by 68%.
- You know the size up front. `StringDict[Int](capacity=n)` removes table
  growth entirely, and an insert then costs 10.0 ns against the stdlib's 10.5.
- You have fewer than 65535 keys. `StringDict[Int, .uint16]` is 12% smaller
  again at no measurable cost in time — see *Narrowing the index*.

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
- You insert into one big map, once, and read it rarely. Building is still
  ~1.15× the stdlib's, the remainder being the key bytes it copies and a
  `Dict` does not.

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
pass), against the stdlib `Dict[String, Int]`. The same suite on an x86-64
machine is further down, under *Linux x86-64 (AVX-512)*, and it does not tell
the same story.

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

| corpus | keys | bytes of keys | StringDict | no cache | stdlib Dict | ratio |
| --- | --- | --- | --- | --- | --- | --- |
| english | 192 | 1034 | **6003** | 5203 | 11536 | 52% |
| german | 208 | 1359 | **7627** | 6427 | 11536 | 66% |
| l33t | 339 | 1685 | **12085** | 10277 | 23056 | 52% |
| french | 418 | 2809 | **13192** | 11384 | 23056 | 57% |
| greek | 320 | 3641 | **14853** | 13045 | 23211 | 64% |
| arabic | 336 | 3338 | **14853** | 13045 | 23082 | 64% |
| hebrew | 231 | 2334 | **10752** | 9552 | 23153 | 46% |
| hindi | 250 | 4555 | **12413** | 11213 | 24386 | 50% |
| georgian | 250 | 4558 | **12413** | 11213 | 25364 | 48% |
| s3_actions | 143 | 3233 | **7848** | 7048 | 13353 | 58% |
| chinese | 10 | 4647 | **5341** | 5277 | 5383 | 99% |
| japanese | 10 | 4992 | 7832 | 7768 | **5728** | 136% |
| **all twelve** | | | **125212** | 111452 | 212844 | **59%** |

The "no cache" column is `caching_hashes=False`, which drops the cached hash per
entry and lands at 52% of the stdlib, in exchange for a build about 1.3× rather
than 1.15×.

#### Narrowing the index

`KeyCountType` caps how many entries a map can hold and sizes the slot index to
match. At `uint16` — 65535 entries, which most dictionaries never approach — two
arrays shrink at once, because the cached hash is sized from the same parameter:
a rehash needs only as many hash bits as the capacity has, so a 16-bit index
means 16 cached bits rather than 32.

| corpus | keys | uint32 | uint16 | saved |
| --- | --- | --- | --- | --- |
| english | 192 | 6003 | **5091** | 15% |
| french | 418 | 13192 | **11264** | 14% |
| german | 208 | 7627 | **6515** | 14% |
| l33t | 339 | 12085 | **10157** | 15% |
| greek | 320 | 14853 | **12925** | 12% |
| arabic | 336 | 14853 | **12925** | 12% |
| hebrew | 231 | 10752 | **9128** | 15% |
| hindi | 250 | 12413 | **10789** | 13% |
| georgian | 250 | 12413 | **10789** | 13% |
| s3_actions | 143 | 7848 | **6936** | 11% |
| **all twelve** | | 125212 | **109564** | **12%** |

That is 4–7 bytes an entry, and it takes the container to **51% of a `Dict`** —
better than turning the hash cache off, while keeping the build speed the cache
buys. Builds and lookups are unchanged: a 16-bit load zero-extends in the same
instruction as a 32-bit one, so the narrower index costs nothing to read.

Measured one index width per process, twice each (`pixi run bench-narrow` and
`bench-narrow-16`). Measuring both in one process gave contradictory answers run
to run — 3% slower one time, 10–28% faster the next — and neither survived a
second look. The footprint column needs no such care; it is counted, not timed.

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
| english | 7.6 | **7.0** | **2.6** | 2.8 |
| german | 8.0 | **7.9** | **3.0** | 3.2 |
| l33t | 7.9 | **7.5** | **2.3** | 2.5 |
| french | 8.8 | **8.6** | **2.7** | 2.9 |
| greek | 9.1 | **8.7** | **2.4** | 2.7 |
| arabic | 10.0 | **9.6** | **2.4** | 2.6 |
| hebrew | 10.0 | **9.6** | **2.3** | 2.5 |
| hindi | 9.5 | **9.3** | **2.3** | 2.6 |
| georgian | 9.1 | 9.1 | **2.3** | 2.5 |
| s3_actions | 7.2 | 7.2 | **2.3** | 2.5 |
| chinese | **37.7** | 57.4 | **2.3** | 2.6 |
| japanese | **53.8** | 58.1 | **2.3** | 2.5 |

Level on every corpus of ordinary words — within a few percent either way — and
misses are consistently a little faster, since the 7-bit tag in the control byte
rejects a wrong key without touching the key bytes at all. On the long CJK keys
the packed buffer pulls well ahead.

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
| english | 11.8 | **10.1** | **10.2** | 18.5 |
| german | 12.3 | **11.2** | **10.8** | 20.0 |
| l33t | 8.4 | **7.4** | **7.8** | 11.2 |
| french | 8.3 | **7.4** | **8.2** | 11.2 |
| greek | 8.6 | **7.7** | **8.0** | 11.2 |
| arabic | 8.2 | **7.5** | **8.1** | 11.2 |
| hebrew | **7.0** | 7.2 | **6.8** | 10.5 |
| hindi | 8.4 | **8.1** | **8.3** | 12.4 |
| georgian | 8.0 | **7.3** | **7.7** | 10.8 |
| s3_actions | 4.0 | **3.9** | **4.4** | 5.2 |
| chinese | 0.9 | **0.4** | 1.1 | **0.7** |
| japanese | 1.0 | **0.4** | 1.2 | **0.8** |

Indexing is about 1.15× the stdlib, and part of what remains is inherent: a
`StringDict` copies each key's bytes into its packed buffer, where a `Dict`
stores a copy-on-write alias and copies nothing. That is the price of the
density, and it shows most on the CJK rows, where the stdlib gets 500 bytes per
key for free. It also means the source strings can be dropped once the map is
built — a `Dict` keeps every one of their allocations alive.

Counting — the same work plus a read per word — is *faster* on eleven of twelve
corpora, because `upsert` settles a word in one probe where a `Dict` needs a read
and then a write. On english that is 81%.

### Many small maps

One map per document, which is the shape of a term-frequency or grouping pass.
Nanoseconds per document.

| document | StringDict | stdlib |
| --- | --- | --- |
| 5 words | **197** | 200 |
| 20 words | **573** | 851 |
| 100 words | **2132** | 2786 |

A map per document is also where the two tuning parameters are easiest to
reason about, since a document's vocabulary is small and known. Twenty-word
documents, one configuration per process:

| configuration | ns per document | footprint |
| --- | --- | --- |
| `uint32` + cache (the default) | 573 | 712 B |
| `uint16` + cache | 571 | 600 B |
| `uint8` + cache | 582 | **568 B** |
| `uint32`, `caching_hashes=False` | 642 | 616 B |
| `uint8`, `caching_hashes=False` | 613 | 520 B |

Two things fall out, and both are the opposite of what seems obvious at this
size. **The hash cache still earns its place**, worth 11% even on a map of
twenty entries that rehashes twice — measured three times, 565/573/585 against
641/643/652. And **narrowing the index saves more memory than dropping the cache
does**, at no cost in time: `uint8` with the cache is smaller *and* faster than
`uint32` without it. If a small map needs to be smaller, narrow
`KeyCountType` before reaching for `caching_hashes=False`.

### Where an insert's time goes

`pixi run bench-anatomy` splits an insert into a fixed cost per map, a
steady-state cost, and a share of the growth it eventually triggers.

| | StringDict | stdlib |
| --- | --- | --- |
| construct + destruct, empty | 38.5 ns | 0.3 ns |
| put, steady state | **10.3 ns** | 12.3 ns |
| insert, 4000 keys, pre-sized | **10.0 ns** | 10.5 ns |
| insert, 4000 keys, growing from empty | **19.1 ns** | 19.4 ns |
| → so growth costs | 9.1 ns | **8.9 ns** |

Growth is more than half of an insert for both containers, and used to be where
this one lost: it cost 11.4 ns against the stdlib's 8.9, because a rehash
recomputed every key's hash. Caching 32 bits of hash per entry removed that, and
the two are now level. Only the constructor is still behind, because the stdlib
`Dict` allocates lazily — which suits a type used for empty dictionaries
everywhere, and this one is not.

### Tuning

| parameter | default | what it buys |
| --- | --- | --- |
| `capacity=n` | 16 | Removes growth, which is the entire insert gap. |
| `destructive` | `True` | `delete`/`pop`/`clear`, for one bit per entry and no measurable time. |
| `caching_hashes` | `True` | A rehash reuses stored hash bits instead of recomputing: growth 11.4 → 9.1 ns, builds 1.3× → 1.15× the stdlib. Costs 4 bytes per entry, about 12% of a map. Turn it off for the smallest footprint. |
| `KeyCountType` | `uint32` | Narrower shrinks the slot index *and* the cached hash: `uint16` is 12% smaller overall at no measurable cost in time. `put` aborts if entries exceed what it can index. |
| `KeyOffsetType` | `uint32` | Caps the total size of all keys together. |

### Linux x86-64 (AVX-512)

The same suite on an AMD Ryzen AI 9 HX 370 (Zen 5, AVX-512), Arch Linux, Mojo
1.2.0.dev2026091205, `performance` power profile. Every task ran twice, one after
another, and each figure is the lower of the two runs; they agreed within a few
percent, apart from one small-map run. A different CPU makes the nanoseconds
incomparable with the Apple tables — what carries over is where each container
stands against the stdlib `Dict` on the same machine.

These tables use the default group, which is **32 lanes** here: AVX-512 offers
64, but the default is capped at 32 because *Group width* below found 64 slower
on every row. A probe compares 32 control bytes per step, and no table is
smaller than 32 slots.

| | Apple M-series | x86-64, AVX-512 |
| --- | --- | --- |
| memory, all twelve corpora | 125212 B | 125131 B |
| `uint16` index saves | 12% | 12% |
| lookup, word present | level with the stdlib | 1.1–1.2× the stdlib |
| lookup, absent | a little faster | 1.2–1.4× the stdlib |
| index a whole corpus | ~1.15× the stdlib | 1.2–1.5× the stdlib |
| count word frequencies | faster on 11 of 12 | faster on 3, level on 3 |
| map per 20-word document | **573** vs 851 ns | **342** vs 503 ns |
| footprint of that map | 712 B | 968 B |

**The memory case survives the move; the speed case does not.** Across whole
corpora the footprint is within 1% of the Apple figure, and narrowing the index
saves the same 12%. Timings are another matter: lookups and builds trail the
stdlib on every corpus, and misses — the fastest path on Apple silicon — trail
it by the most.

#### Memory

Bytes for a map holding every distinct word, from `bench-narrow`. The stdlib
column of the Apple table has no benchmark behind it in this repository, so it
is not repeated here.

| corpus | keys | uint32 | uint16 | Apple, uint32 |
| --- | --- | --- | --- | --- |
| english | 192 | 6711 | **5695** | 6003 |
| german | 208 | 7363 | **6347** | 7627 |
| l33t | 339 | 10707 | **8923** | 12085 |
| french | 418 | 14781 | **12613** | 13192 |
| greek | 320 | 13152 | **11368** | 14853 |
| arabic | 336 | 13152 | **11368** | 14853 |
| hebrew | 231 | 9621 | **8093** | 10752 |
| hindi | 250 | 13289 | **11761** | 12413 |
| georgian | 250 | 13289 | **11761** | 12413 |
| s3_actions | 143 | 8440 | **7592** | 7848 |
| chinese | 10 | 7313 | **7185** | 5341 |
| japanese | 10 | 7313 | **7185** | 7832 |
| **all twelve** | | 125131 | **109891** | 125212 |

The total lands within 0.1% of the Apple figure, but individual corpora move by
up to 12% either way, because the group width changes where the table and the
key buffer grow. The ten-key chinese map is the outlier, 37% bigger.

#### Lookups

Nanoseconds per lookup, probing with independently allocated strings as above.

| corpus | every word, present | | probe from another script | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 8.7 | **7.3** | 3.9 | **2.9** |
| german | 9.3 | **7.9** | 4.5 | **3.2** |
| l33t | 8.8 | **7.5** | 3.6 | **2.7** |
| french | 9.6 | **8.0** | 4.1 | **3.0** |
| greek | 11.4 | **9.6** | 3.8 | **2.8** |
| arabic | 10.6 | **9.0** | 3.6 | **2.7** |
| hebrew | 10.6 | **8.9** | 3.3 | **2.7** |
| hindi | 16.3 | **14.5** | 3.2 | **2.7** |
| georgian | 14.0 | **11.8** | 3.6 | **2.8** |
| s3_actions | 17.4 | **14.7** | 3.5 | **2.7** |
| chinese | 34.1 | **30.9** | 3.2 | **2.7** |
| japanese | 35.9 | **32.9** | 3.3 | **2.7** |

A miss with the table 85% full costs 4.0 ns against the stdlib's 3.3.
With `caching_hashes=False` lookups are slightly *faster* — hits by up to 6%,
misses by 2–9% — except that 85%-full miss, which is 7% slower.

#### Building

Microseconds for a whole corpus.

| corpus | index every word | | count word frequencies | |
| --- | --- | --- | --- | --- |
| | StringDict | stdlib | StringDict | stdlib |
| english | 15.0 | **10.2** | **12.2** | 17.8 |
| german | 15.9 | **11.5** | **12.9** | 19.2 |
| l33t | 10.8 | **7.1** | 10.9 | **9.8** |
| french | 10.8 | **7.3** | 11.6 | **9.8** |
| greek | 10.9 | **8.2** | 11.1 | **11.0** |
| arabic | 10.8 | **7.9** | 11.1 | **10.7** |
| hebrew | 9.6 | **7.1** | 9.7 | **9.6** |
| hindi | 12.6 | **10.5** | **12.4** | 15.0 |
| georgian | 10.4 | **8.1** | 10.8 | 10.8 |
| s3_actions | 4.9 | **4.0** | 5.4 | **5.0** |
| chinese | 0.6 | **0.4** | 0.9 | **0.7** |
| japanese | 0.7 | **0.4** | 1.0 | **0.7** |

`upsert` wins clearly on english and german, where each distinct word occurs
about five times, and on hindi; it is level on georgian, greek and hebrew, and
loses on the other six.

#### Where an insert's time goes

| | StringDict | stdlib | Apple, StringDict vs stdlib |
| --- | --- | --- | --- |
| construct + destruct, empty | 13.4 ns | **0.2 ns** | 38.5 vs 0.3 |
| put, steady state | **14.3 ns** | 15.8 ns | 10.3 vs 12.3 |
| insert, 4000 keys, pre-sized | **12.6 ns** | 17.9 ns | 10.0 vs 10.5 |
| insert, 4000 keys, growing from empty | 31.8 ns | **26.9 ns** | 19.1 vs 19.4 |
| → so growth costs | 19.2 ns | **9.0 ns** | 9.1 vs 8.9 |

This is the clearest result on this machine, and it points at one place. **A
pre-sized insert beats the stdlib by 30%; growth costs twice what the stdlib's
does.** And the hash cache, which closed the growth gap on Apple silicon, does
almost nothing for it here: growth is 19.6 ns with `caching_hashes=False`
against 19.2 with it on. So growth on this machine is not paying for hashing.
Part of it was the group width — at the old 64-lane default growth cost 23.1 ns
(see *Group width*) — and the rest has not been isolated.

The practical consequence is the same as before, with more weight: **if you know
the size, pass `capacity=n`**, and on this machine that is the difference
between trailing the stdlib and beating it.

#### Many small maps

Twenty-word documents, one configuration per process; nanoseconds per document.

| document | StringDict | stdlib |
| --- | --- | --- |
| 5 words | 131 | **129** |
| 20 words | **342** | 503 |
| 100 words | 2347 | **2044** |

| configuration | ns per 20-word document | footprint |
| --- | --- | --- |
| `uint32` + cache (the default) | 342 | 968 B |
| `uint16` + cache | 343 | 840 B |
| `uint8` + cache | 352 | 808 B |
| `uint32`, `caching_hashes=False` | 340 | 840 B |
| `uint8`, `caching_hashes=False` | 350 | **744 B** |

Twenty-word documents are a clear win, five words is about level, and a hundred
is not. A small map takes 968 B here against 712 on Apple silicon, and the
difference is the table floor, which is the group width: built with
`-D GROUP=16` the same map is exactly 712 B, and at the old 64-lane default it
was 1928. The Apple finding that the cache earns its place on small maps does
not reproduce: with it off the time is within noise. On this machine, if a
small map needs to be smaller, narrowing the index and dropping the cache are
each free on their own; together they save 23% for about 2% in time.

#### Group width

The group used to default to the widest SIMD register the target has — 64 lanes
here. It is now capped at 32 because of this table, and `-D GROUP=n` overrides
it. The same benchmarks at 64, 32 and 16 lanes, the three widths
interleaved over two rounds, lower of the two; the 55 tests pass at all three.

| | 64 (old default) | 32 (default) | 16 | stdlib |
| --- | --- | --- | --- | --- |
| index english, µs | 16.1 | **14.8** | 19.1 | 10.3 |
| index french, µs | 12.5 | **10.7** | 13.8 | 7.4 |
| count english, µs | 13.3 | **12.1** | 15.7 | 17.7 |
| hit, english, ns | 9.1 | **8.6** | 11.1 | 7.3 |
| hit, hindi, ns | 17.0 | **16.3** | 20.6 | 14.3 |
| miss, english, ns | 5.2 | **3.9** | 4.5 | 2.9 |
| miss, german, ns | 6.2 | **4.4** | 5.6 | 3.1 |
| miss, table 85% full, ns | 5.3 | **4.1** | 5.7 | 3.3 |
| put, steady state, ns | 15.2 | **14.3** | 17.8 | 15.9 |
| insert, pre-sized, ns | 14.7 | **12.6** | 15.3 | 18.0 |
| → growth, ns per insert | 23.1 | **19.1** | 25.7 | 8.2 |
| 20-word document, ns | 389 | **338** | 666 | 504 |
| 20-word document, bytes | 1928 | 968 | **712** | |

**On this CPU, 32 lanes is better than 64 on every timed row**: misses 20–29%
faster on the word corpora (6–8% on the CJK pair), hits 4–7%, builds 7–14%,
growth 17%, and a small map at half the bytes.
Word counting then beats or matches the stdlib on six corpora, against three
wins at 64. Sixteen lanes is not better still — it is the slowest on
nearly everything, and a 20-word document costs twice what it does at 32, which
is the opposite of Apple silicon, where 16 is the native width and small maps
beat the stdlib at it.

The width is not the whole gap. At 32, hits still trail the stdlib by 1.1–1.2×,
builds by 1.2–1.5×, and growth by 2×.

#### Deletion support

`destructive=True` against `False`, one per process: builds, hits and misses are
identical within a few tenths of a nanosecond on every corpus, and at 28000 keys
— 25.5 ns an insert, 14.6 ns a hit, 4.1 ns a miss either way — the tombstone
mask is 4152 bytes of a 1080106-byte map (0.4%). As on Apple silicon, it is
free.

## Development

```bash
pixi run test                   # the test suite (55 tests)
pixi run main                   # the example
pixi run format                 # mojo format
pixi run docs                   # docstring check
pixi build                      # the conda package

pixi run bench                  # the corpus tables above
pixi run bench-small-maps       # one map per document
pixi run bench-small-maps-16    #   ... with a uint16 index
pixi run bench-small-maps-8     #   ... with a uint8 index
pixi run bench-small-maps-plain #   ... with caching_hashes off
pixi run bench-narrow           # KeyCountType uint32, alone
pixi run bench-narrow-16        # KeyCountType uint16, alone
pixi run bench-anatomy          # where an insert's time goes
pixi run bench-destructive      # destructive=True, one variant per process
pixi run bench-non-destructive  # destructive=False, likewise
pixi run bench-uncached         # the corpus tables with caching_hashes off
pixi run bench-anatomy-uncached # the anatomy with caching_hashes off
```

To try another SIMD group width, add `-D GROUP=32` (or 16) to any `mojo`
command; see *Group width*.

Every task needs pixi 0.80 or newer. `pixi.lock` is a version 7 lock file, and
an older pixi does not refuse it — it treats the lock as missing and rewrites
it.

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
