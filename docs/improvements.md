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

### Done, partly: fewer allocations, the way the trees do it

The six regions are two families on different schedules, so they cannot all be
one block:

| | sized by | grows | factor |
| --- | --- | --- | --- |
| `control`, `slot_to_index` | slot capacity | in `_rehash`, at 7/8 load | 2x |
| `keys`, `keys_end` | key bytes, entry count | in `KeysContainer.add` | 1.5x |
| `entry_hashes`, `deleted_mask` | entry count | on insert, paired to `_keys.capacity` | 2x |

Building 5000 keys the families track loosely and never coincide -- 8192 slots
against an entry capacity of 4618, 2048 against 913. Under churn they diverge
outright: 20000 inserts with every other key deleted ends at 16384 slots
against an entry capacity of 23377, the entry side the larger, because entries
are never renumbered while a rehash drops tombstones.

**The slot family is a true merge, and it is done.** `control` and
`slot_to_index` are both exactly `capacity` long and always reallocated
together, so they share one block: indices first, being the more strictly
aligned, control bytes after. The zero-count allocations for switched-off
features are gone too -- `alloc({count = 0})` is still a full round trip
through the allocator -- so with `caching_hashes` off the map no longer pays
for an `entry_hashes` array it will never read.

Seven allocations per map became five:

| | before | after |
| --- | --- | --- |
| construct + destruct, empty | 269.6 ns | 188.2 ns |
| per-document word count, 5-word docs | 337 ns | 255 ns |
| per-document word count, 20-word docs | 839 ns | 699 ns |
| per-document word count, 100-word docs | 2756 ns | 2429 ns |

An allocation round trip costs about 37 ns here and is linear in the count, so
the constructor was essentially just its allocations. Corpus builds and the
insert path are unchanged.

#### The merge cost 8-23% until the pointers were hoisted

The first version of this regressed every corpus build -- english 15.0 to 16.2
us, french 10.9 to 13.4, greek 10.6 to 12.5 -- consistently and far outside the
3-5% run-to-run noise, while the small-map numbers improved. Two allocations
that were provably distinct became one, and the compiler could no longer tell a
store through `slot_to_index` from a load through `control`, so it reloaded
both fields on every pass of the probe loop.

Loading each pointer into a local once, at the top of `put`, `_find_slot` and
`_rehash`, recovers all of it and leaves a few corpora slightly ahead of where
they started. Worth remembering as a general consequence: merging allocations
takes away alias information the hot loop was relying on, and the fix is to
hoist, not to give up the merge.

#### Why this matters here, and deferral does not

The stdlib `Dict` defers allocation until its first insert because empty dicts
are everywhere in ordinary Mojo. That reasoning does not carry over: a
`StringDict` is reached for deliberately and is rarely empty. But it is often
*small* -- one map per document is the shape of a term-frequency or grouping
pass, which is exactly what this container is for -- and deferral does nothing
for a map that receives even one insert, while a cheaper constructor helps
every one of them. Per-document counting went from losing to the stdlib `Dict`
at 20 words to winning by 16%, and by 15% at 100 words.

**The entry family is merged too, and the keys with it.** Everything indexed by
entry -- the cached hashes, the key end offsets, the values and the tombstone
mask -- now shares one block with a single `entry_capacity`. `KeysContainer` is
gone: the packed key bytes are a field of the map, and the end offsets that used
to live beside them moved into the entry block, where they belong.

The split is by growth trigger, which is the only thing that separates these
regions. Three allocations per map:

| | holds | grows when |
| --- | --- | --- |
| key buffer | every key's bytes, end to end | the bytes run out |
| entry block | end offsets, hashes, values, mask | the entry count runs out |
| slot block | control bytes, slot to entry index | the table passes 7/8 load |

The entry regions had been on *two* schedules by accident -- `keys_end` grew by
half inside `KeysContainer` while the rest doubled, and a floor meant to pair
them almost never bound. Tracing a build showed them interleaving rather than
coinciding: 16/24/36/54/81 against 16/32/64/128. There is exactly one entry per
key, so one capacity always sufficed; they now grow by half together, which is
also a third less overshoot than doubling on the regions that carry most of what
an entry costs.

Giving up `List[V]` for raw storage is what made this possible: growth moves the
values with `unsafe_uninit_move_n`, the destructor runs `unsafe_destroy_n` over
every entry ever added (deleted ones included, since entries are never
renumbered), and the copy constructor copies them one by one while the offsets,
hashes and mask go by `memcpy`. The block is allocated as `UInt64` rather than
as bytes, which is what gives the hash region its 8-byte alignment -- the
installed `Layout` has no explicit-alignment constructor and a byte allocation
promises nothing -- and the value region is rounded up to `align_of[V]()`, which
matters when the end offsets are narrower than the values.

Three allocations per map now, from seven at the start:

| | 7 allocs | 5 | 4 | 3 |
| --- | --- | --- | --- | --- |
| per-document count, 5-word docs | 337 ns | 255 | 216 | **169** |
| per-document count, 20-word docs | 839 ns | 699 | 608 | **519** |
| per-document count, 100-word docs | 2756 ns | 2429 | 2177 | **1961** |
| index the english corpus | 15.0 us | 15.0 | 13.1 | **12.9** |

Against the stdlib `Dict`, per-document counting began this sequence losing at
every size and now wins at every size: 169 ns against 204 at five words, 519
against 834 at twenty, 1961 against 2823 at a hundred.

**What it cost.** An insert into a map that never grows went from 10.0 ns to
11.4, about 14%. Hoisting the region pointers in `put` -- the same fix the slot
merge needed -- recovered part of it but not all; what is left is presumably
more of the same, four regions in one allocation being harder for the compiler
to keep un-aliased than four separate ones. It is a good trade at any realistic
size: a twenty-word document pays 28 ns of extra inserts against roughly 120 ns
of constructor it no longer pays, and whole-corpus builds are unchanged.

### Killed by measurement: interleaving the end offset with the value

This was the most promising remaining idea in this document, and it was wrong.
The claim: `keys_end[i]` and `values[i]` are written on the same insert and read
together on any lookup that returns a value, from two separate arrays, so
interleaving them into one record would put both on one cache line.

Both halves fail to measure, on maps far too large to cache. Comparing
`key in map` against `map.get(key)` isolates the value load:

| | 1000 keys | 28000 keys | 200000 keys |
| --- | --- | --- | --- |
| `key in map` | 10.5 ns | 13.4 ns | 16.4 ns |
| `map.get(key)` | 10.6 ns | 13.8 ns | 16.5 ns |
| so the value load costs | 0.1 ns | 0.4 ns | 0.1 ns |

It is nearly free because it is not on the critical path: by the time it
happens the lookup has already read two end offsets and compared the key bytes,
and the load overlaps with all of that.

The write side is no better. Shrinking the value type from 8 bytes to 1 -- which
cuts the value array at 28000 entries from 224KB to 28KB, eight times fewer
cache lines touched -- leaves the insert at **4.7 ns either way**, unchanged to
the tenth of a nanosecond.

And it would cost memory in the one dimension this container exists for. A
record of `{UInt32, Int}` is 16 bytes where the two arrays are 12, and
`{UInt32, UInt8}` is 8 where they are 5: 4 and 3 bytes of padding per entry, a
third to three fifths more for those arrays, around 11% of a whole map.

Nothing measurable gained, paid for in footprint. Not built.

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

## 2. Resolved: the long-key "gap" was the benchmark, not the map

Present-key lookups on the CJK corpora appeared to run 1.5-2x slower than the
stdlib `Dict`, and the gap grew with key length. It is gone, and nothing in this
container changed -- the benchmark was wrong.

Mojo's `String` is copy-on-write. `d[key] = v` on a `Dict[String, V]` stores a
key that **shares its buffer** with the string handed in: ten of ten stored keys
aliased the inserted object when checked, and `String.copy()` returns a string
with the same data pointer. So when the benchmark stored `words[i]` and then
probed with that same `words[i]`, `String.__eq__` answered on pointer identity
and never read the bytes. A `StringDict` copies keys into its packed buffer and
can never do that, so the two sides were not doing the same work.

Probing with an equal but independently allocated string, on the japanese
corpus (499-byte keys):

| | probe is the inserted object | probe is a fresh copy |
| --- | --- | --- |
| stdlib `Dict` | 27.6 ns | 52.3 ns |
| `StringDict` | 51.9 ns | 53.4 ns |

The stdlib's advantage is entirely the short-circuit. With a fair probe the two
are level, and on the 464-byte chinese keys the packed buffer is 24% *ahead*
(38.8 ns against 50.7).

How the arithmetic gave it away: hashing one 499-byte key costs 23.9 ns and
comparing two costs about 12, so a real lookup cannot come in under ~36. The
stdlib was measuring 27.4. That is what a missing comparison looks like, and it
was worth chasing rather than filing as noise.

Two things follow for the rest of this document. The benchmark now probes with
fresh strings. And the same copy-on-write explains part of the *build* gap,
which is not a benchmark artifact but a real design cost: a `Dict` stores an
alias and copies no key bytes at all, while a packed buffer must copy every one.
The compensation is that the source strings can then be dropped, where a `Dict`
pins every one of their allocations.

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

One part of the merge looked like it stood on its own -- interleaving an
entry's end offset with its value, so both land on one cache line. It was
measured and does not pay; see "Killed by measurement: interleaving the end
offset with the value" under item 1.

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
