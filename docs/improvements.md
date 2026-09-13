# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Inserts are ~1.5x behind the stdlib `Dict`

Indexing the english corpus takes 14.5 us against the stdlib's 10.0, and every
corpus shows the same ratio. Lookups are level; inserts are not.

The structural cause is visible without profiling: a `put` writes into four
regions that grow independently -- the packed key bytes, the end offsets, the
slot table and the values -- where a `Dict` appends one entry to one array.
That is the same thing item 4 proposes to fix, and it is the more promising of
the two framings.

Two other candidates are worth a measurement each: the two group scans `put`
does (one for an existing key, one for a free slot), and the tombstone-mask
growth check on every insert.

Note that `upsert` already beats the stdlib by 35% on corpora with heavy word
repetition (english, german), because it settles a word in one probe where a
`Dict` needs a read and then a write. The insert gap only decides the outcome
when a corpus is mostly distinct words.

### Killed by measurement: splitting the growth path out of `KeysContainer.add`

`add` is `@always_inline` and carries two full realloc paths in its body. In
`mm_lcrs_tree` exactly that shape cost 20% -- `_reserve` had grown too large to
inline, and splitting it into an `@always_inline` fast path plus an
`@no_inline` `_grow` took a node from 5.8 ns to 3.4.

The same split here is consistently **2-3% slower**, in the same direction on
all ten sizeable corpora (english 14.5 -> 15.1 us, german 14.7 -> 15.2). The
difference is that `add`'s hot path is a few instructions around a `memcpy`,
so the call and the register spills at the growth site cost more than the
smaller body saves. Reverted; the lesson does not generalise.

## 2. Long keys: a lookup gap that grows with key length

Present-key lookups are level with the stdlib `Dict` on every corpus of
ordinary words, but not on the two CJK ones, whose "words" are whole paragraphs:

| corpus | avg key bytes | StringDict | stdlib |
| --- | --- | --- | --- |
| hindi | 18 | 8.7 ns | 9.0 ns |
| chinese | 464 | 37.7 ns | 24.4 ns |
| japanese | 499 | 48.6 ns | 27.3 ns |

The gap grows faster than the key length, which rules out a fixed per-lookup
cost. It is unexplained. Both sides hash the whole key with the same builtin
`hash`, and both bottom out in the same stdlib `StringSlice` comparison for the
final byte-for-byte check; the only structural difference on the read path is
that reconstructing a key here costs two dependent loads from the end-offset
array before the comparison can start, and that should be a couple of
nanoseconds, not twenty.

Worth profiling rather than guessing at. A cheap first check: measure a hit
against a miss that shares the same tag, which separates comparison cost from
hashing cost.

## 3. Deleted entries still hold their key bytes and value

A deleted entry's slot is reclaimed -- `_rehash` drops tombstones and an insert
can take a deleted slot -- but its key bytes stay in the packed buffer and its
value stays in the list, because entries are addressed by a dense index that
nothing renumbers. A map that churns therefore grows in key storage even though
the table does not.

`_rehash` is the place to fix it: it already visits every live entry, so it
could compact the key buffer and the value list at the same time and renumber
the slots it is rebuilding anyway. The cost is that any `StringSlice` a caller
is holding into the key buffer would be invalidated.

## 4. Values sit in a `List`, keys do not

The keys avoid a per-entry allocation; the values do not avoid a `List`. That
is fine in itself, but it means a map owns four growable regions that grow
independently -- keys, key offsets, values, and the slot table. Holding them in
one allocation, the way `mm_fiby_tree` and `mm_lcrs_tree` do, would cut the
allocation count per map and shrink the handle.

## 5. Smaller items

- **`items()` copies the value**, though `values()` yields references. An
  `Entry` holding a reference would need the caller to write `entry.value[]`,
  which stops it reading like the stdlib `Dict`.
- **`get` copies the value.** Returning a reference would avoid it for
  heap-owning value types, as `mm_fiby_tree`'s iterator now does, but it needs
  a sentinel story for the absent case — probably `Optional[ref]` or a
  `get_ptr`.
- **`upsert` calls `update(None)` for a revived entry**, discarding the value
  the entry had before it was deleted. That is defensible, but it is a
  behaviour worth stating in the docstring rather than leaving to be
  discovered.
- **No `KeyCountType` overflow check.** Exceeding 65535 entries with
  `uint16` silently wraps the one-based slot index.
