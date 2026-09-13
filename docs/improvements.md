# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Inserts are ~1.4x behind the stdlib `Dict`

Indexing the english corpus takes 14.5 us against the stdlib's 9.9. Taking an
insert apart (`pixi run bench-anatomy`) says where that goes, and it is not
where "inserts are slower" suggests:

| | StringDict | stdlib |
| --- | --- | --- |
| construct + destruct an empty map | 269.6 ns | 0.2 ns |
| put, steady state, no growth or new keys | 10.8 ns | 11.8 ns |
| insert, 4000 distinct keys, pre-sized | 10.8 ns | 10.4 ns |
| insert, 4000 distinct keys, growing from empty | 23.0 ns | 19.4 ns |
| so growth costs | 12.3 ns | 9.0 ns |

Three separate findings:

1. **Steady state is already even**, and slightly ahead. The probe and its
   writes are not the problem.
2. **Pre-sized, the gap is 4%.** Give the map its capacity up front and there
   is essentially nothing in it.
3. **Growth is more than half of an insert** for both implementations, and
   ours costs 3.3 ns more per insert than theirs. That is the whole gap.

Inside growth, `_rehash` recomputes `hash()` for every entry it moves, because
neither the 7-bit control byte nor the slot a key sat in can rebuild a tag for
the doubled table. Doubling moves about two entries per insert amortized, and
one hash of a 10-byte key is 1.2 ns. Turning on `caching_hashes` removes that
work and recovers 1.4 of the 3.3 ns -- see below; the rest of the gap is still
open.

### Done: `_rehash` reuses hashes, behind `caching_hashes`

`caching_hashes` used to store a hash narrowed to `KeyCountType`, per *slot*,
which was useless to a rehash on both counts -- narrowed it cannot rebuild a
tag, and keyed by slot it does not survive the rehash that invalidates every
slot. It now stores the full 64-bit hash per *entry*, and `_rehash` reuses it:

| | caching off | caching on | stdlib |
| --- | --- | --- | --- |
| insert, growing from empty | 23.2 ns | 21.9 ns | 19.3 ns |
| of which growth | 12.3 ns | 10.9 ns | 9.1 ns |
| corpus build (english) | 15.3 us | 14.9 us | 10.2 us |
| corpus build (l33t) | 10.7 us | 9.9 us | 7.3 us |

Growth is 11% cheaper and the gap to the stdlib on growth halves, 3.1 ns to
1.5. Corpus builds gain 4-7%.

Two things it did **not** do, both worth recording because the first was
predicted and wrong:

- **The saving is 1.4 ns per insert, not the 2.4 predicted** from two hashes at
  1.2 ns each. Doubling moves about two entries per insert amortized, so the
  arithmetic was right about how many hashes are skipped; skipping them just
  frees less than their standalone cost, the loop around them having plenty
  else to wait on.
- **Lookups are unchanged, long keys included.** The stored hash also acts as a
  filter in `_matches` before the key comparison, and that was expected to pay
  on the CJK corpora, where a comparison runs to 500 bytes. It does not: a
  lookup that finds its key compares the bytes regardless, and the control
  byte already rejects 127 of every 128 wrong slots, so the filter almost never
  fires.

It stays off by default. 8 bytes per entry measured 19-34% of a whole map on
the corpora, and a 4-7% build gain does not buy that in a container chosen for
footprint. It is the right switch for an insert-heavy map that grows.

### Fewer allocations, the way the trees do it

`mm_fiby_tree` and `mm_lcrs_tree` hold all their index regions in one
allocation. The same treatment here would merge the three capacity-sized arrays
-- control bytes, slot indices and cached hashes, which are already reallocated
together in `_rehash` -- into one region, and take a constructor from six
allocations to four.

Measured against the numbers above, this is worth doing for the **fixed cost**,
not for the insert gap: growth allocates O(log n) times over a build, which is
nothing per insert, so merging cannot touch the 3.3 ns. What it touches is the
269.6 ns to construct a map, which matters when a program holds many small maps
rather than one big one -- and for the ten-key CJK corpora, where construction
is about a quarter of the measured build.

For that fixed cost, though, the bigger lever is **allocating nothing until the
first insert**, which is what the stdlib `Dict` does to reach 0.2 ns. Merging
six allocations into four removes perhaps a third of the constructor; deferring
them removes all of it. Worth doing in that order.

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
is fine in itself, but it means a map owns six allocations that grow
independently -- keys, key offsets, values, slot indices, control bytes and the
tombstone mask.

Item 1 covers what merging them is and is not worth. The short version: it buys
back part of a 269.6 ns constructor and nothing per insert, and deferring the
allocations entirely buys back more of it than merging does.

One part of the merge does stand on its own, though, and is not about
allocation count: the end offset and the value for an entry are written on
every insert and read together whenever a lookup returns a value, and they sit
in two separate arrays. Interleaving them into a single entry array would put
both on one cache line. That is a locality change rather than an allocator one,
and unlike the rest of the merge it could plausibly move the steady-state
number.

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
