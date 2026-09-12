# mm_string_dict

[![CI](https://github.com/Mojo-Mania/mm_string_dict/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_string_dict/actions/workflows/ci.yml)

A hash map from string keys to arbitrary values for
[Mojo](https://mojolang.org), with the keys stored compactly.

The keys do not live in individual `String`s. They are appended end to end into
one byte buffer, with a parallel array of end offsets, so a key costs its bytes
plus one offset — no per-key header, no per-key allocation. Lookups compare
against slices of that buffer.

The map itself is open addressing with linear probing over a power-of-two slot
array. A slot holds a **one-based** index into the key and value arrays, so
zero means "empty" and no separate occupancy bitmap is needed.

```mojo
from mm_string_dict import StringDict

var counts = StringDict[Int]()
counts.put("apple", 1)
counts.put("pear", 2)

print(counts.get("apple", 0))   # 1
print("pear" in counts)         # True
print(len(counts))              # 2
```

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
StringDict[Int, DType.uint32, DType.uint32, True, False]  # don't cache hashes
```

| Parameter | Default | What it costs |
| --- | --- | --- |
| `V` | — | The value type; anything copyable. |
| `KeyCountType` | `uint32` | Indexes keys and slots, so it caps the entry count. |
| `KeyOffsetType` | `uint32` | Holds key end offsets, so it caps the **total** size of all keys. |
| `destructive` | `True` | One bit per entry for the tombstone mask. Off means `delete` does nothing. |
| `caching_hashes` | `True` | `KeyCountType` bytes per slot, and worth it — see below. |

## API

| Member | Meaning |
| --- | --- |
| `put(key, value)` | Insert, or replace the value if the key is there. |
| `get(key, default) -> V` | The value, or `default` when absent or deleted. |
| `key in dict`, `len(dict)` | Membership, entry count. |
| `delete(key)` | Tombstone an entry, if `destructive`. |
| `upsert(key, update)` | Insert or update with a function of the current value, looking the key up once. |
| `clear()` | Drop every entry, keep the storage. |
| `dict.keys` | The `KeysContainer`: `keys[i]`, `len`, `keys_vec()`, `print_keys()`. |

## Performance

20000 entries of 12 random characters, Apple M-series, nanoseconds per
operation, release build (`-D ASSERT=none`, which is what `pixi run bench`
passes). Reproduce with `pixi run bench`.

| Operation | StringDict | stdlib `Dict[String, Int]` |
| --- | --- | --- |
| build | 23.1 | **19.2** |
| lookup, present | 16.8 | **12.8** |
| membership, absent | 5.6 | **3.7** |
| build, 64-byte keys | 28.9 | **19.9** |

**The stdlib `Dict` is faster here, and this is not a speed play.** What this
one buys is key density: 20000 twelve-byte keys occupy 240000 bytes, and the
container holds them in 283702 bytes of buffer plus 80000 bytes of offsets —
about 1.5 bytes of overhead per key. A `Dict[String, Int]` stores a `String`
per entry instead, which is 24 bytes of header each before any of its bytes,
and a separate allocation each once a key outgrows the inline buffer.

So: reach for this when you hold a great many string keys and care about
footprint, or when you want the keys contiguous for other reasons. Reach for
the stdlib `Dict` when you want the fastest lookups.

Caching hashes earns its keep:

| build, per insert | |
| --- | --- |
| `caching_hashes=True` (default) | **24.9** |
| `caching_hashes=False` | 30.7 |

## Development

```bash
pixi run test     # the test suite (30 tests)
pixi run bench    # the benchmarks above
pixi run main     # the example
pixi run format   # mojo format
pixi run docs     # docstring check
pixi build        # build the conda package (needs pixi >= 0.80)
```

## Provenance

This is Maxim Zaks' `StringDict`, which also lives in the Mojo standard
library's benchmark suite. Packaged here as a library, with tests, benchmarks
and three bug fixes — see [`docs/fixes.md`](docs/fixes.md).

## License

MIT. See [LICENSE](LICENSE).
