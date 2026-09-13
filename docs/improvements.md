# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Inserts are ~1.4x behind the stdlib `Dict`

Indexing the english corpus takes 14.5 us against the stdlib's 9.9, and every
corpus shows a similar ratio. Lookups are level; inserts are not.

The structural cause is visible without profiling: a `put` writes into four
regions that grow independently -- the packed key bytes, the end offsets, the
slot table and the values -- where a `Dict` appends one entry to one array.
That is the same thing item 4 proposes to fix, and it is the more promising of
the two framings.

The remaining candidate worth a measurement is the two group scans `put` does,
one for an existing key and one for a free slot.

Note that `upsert` already beats the stdlib on ten of the twelve corpora,
because it settles a word in one probe where a `Dict` needs a read and then a
write. The insert gap only decides the outcome when a corpus is nearly all
distinct words.

### Fixed: the tombstone mask check cost 19% of an insert

`destructive=True` is the default, and it used to make inserts 19% slower than
`destructive=False` (25.2 ns against 20.3 at 28000 keys). The bit itself was
never the problem. `_reserve_deleted_bit` was `@no_inline` and did its bounds
check *inside* the function, so every insert paid for a call to learn that the
mask was already big enough.

Hoisting the check into the caller and leaving only the reallocation behind
`@no_inline` -- the `_reserve`/`_grow` split from `mm_lcrs_tree` -- took the
insert to 19.7 ns, level with the non-destructive variant, and pulled 8-16% off
the corpus builds. Deletion support now costs 1 bit per entry and no measurable
time. See the table in the README.

The mask is also sized to the keys container's entry capacity when it grows,
rather than doubling on its own from one byte, which drops it from four
reallocations to two while building a 200-key map. That change is **below
measurement noise** on its own -- same-code runs vary by 3-5% -- and is kept for
the reduced allocator traffic, not for a speedup.

### Killed by measurement: splitting the growth path out of `KeysContainer.add`

`add` is `@always_inline` and carries two full realloc paths in its body, the
same shape that the fix above exploited. Splitting it the same way is
consistently **2-3% slower**, in the same direction on all ten sizeable corpora
(english 14.5 -> 15.1 us, german 14.7 -> 15.2).

The difference between the two cases is where the cheap check already sat. In
`_reserve_deleted_bit` the hot path was a function call; in `add` it is a few
instructions around a `memcpy` that were already inline, so the split only
added a call and register spills at the growth site. Reverted.

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
