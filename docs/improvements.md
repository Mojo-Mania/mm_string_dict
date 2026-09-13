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
allocation. The obvious question is whether the six here can be one region,
since they all grow. They cannot, because they are two families on different
schedules:

| | sized by | grows | factor |
| --- | --- | --- | --- |
| `control`, `slot_to_index` | slot capacity | in `_rehash`, at 7/8 load | 2x |
| `keys`, `keys_end` | key bytes, entry count | in `KeysContainer.add` | 1.5x |
| `entry_hashes`, `deleted_mask` | entry count | on insert, paired to `_keys.capacity` | 2x |

Measured on a build of 5000 keys, the two families track each other loosely
but never coincide -- 8192 slots against an entry capacity of 4618, 2048
against 913. Under churn they diverge outright, since entries are never
renumbered and a rehash drops tombstones: inserting 20000 keys and deleting
every other one ends with 16384 slots and an entry capacity of 23377, the
entry side larger than the slot side.

So a merge is two regions, not one:

- **The slot family is a true merge.** `control` and `slot_to_index` are both
  exactly `capacity` long and are always reallocated together in `_rehash`.
- **The entry family could be merged**, but only by first putting its members
  on one shared growth schedule, which today they do not share.

What it is worth is the harder question, and the honest answer is: not much for
speed. Every allocation-count change measured in this library so far has come
out inside the noise, because growth allocates O(log n) times over a build.
The measured prize is the **269.6 ns constructor** (six allocations against the
stdlib `Dict`'s zero), which matters for programs holding many small maps. And
even there, deferring allocation until the first insert removes more of it than
merging six into three would.

There is one part of the entry family that is not about allocation count at
all, and is the most promising piece: `keys_end[i]` and `values[i]` are written
on the same insert and read together on any lookup that returns a value, from
two separate arrays. Interleaving *those two* puts both on one cache line. That
is a locality change, and unlike the rest it could move the steady-state
number -- though note the steady-state number is already ahead of the stdlib
(11.4 ns against 12.0), so the headroom is small.

### Killed by measurement: dropping a redundant zero-fill

`slot_to_index` is zeroed on construction and on every rehash, and the zero is
never read: every access to it is already guarded by the control byte, which
says whether a slot is occupied before its index is touched. Removing both
fills is provably dead work -- `capacity * 4` bytes of `memset` per rehash, 32KB
at 8192 slots.

It measures as nothing. Four runs, two each way, overlap completely (22.8/24.0
against 23.4/24.0 ns per insert). Restored, because "an empty slot's index is
zero" is a real invariant that a future reader could reasonably lean on, and
giving it up bought nothing.

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
- ~~**No `KeyCountType` overflow check.**~~ Fixed. Exceeding the cap wrapped
  the one-based entry index and the map returned other keys' values with no
  error at all: 300 keys into a `uint8` map gave 45 wrong reads out of 300,
  with `len()` reporting 300. `put` now checks, and aborts with the cap, the
  offending entry number, and the fact that deleted entries count toward it.
  The check is emitted only for index types narrower than 32 bits, where the
  cap is reachable; `uint32` and wider pay nothing. It is a plain check rather
  than a `debug_assert`, because the failure is a wrong answer rather than a
  crash and `debug_assert` compiles out at the assertion levels a release build
  uses -- it did not fire on the reproduction until `-D ASSERT=all`.
