# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Resolved: the build gap was table growth, and growth was re-hashing

Indexing a corpus used to take about 1.3x what the stdlib `Dict` took. Taking an
insert apart (`pixi run bench-anatomy`) put the whole of it in one place:

| | before | now | stdlib |
| --- | --- | --- | --- |
| put, steady state | 10.5 ns | **10.3 ns** | 12.3 ns |
| insert, 4000 keys, pre-sized | 11.4 ns | **10.0 ns** | 10.5 ns |
| insert, 4000 keys, growing from empty | 22.9 ns | **19.1 ns** | 19.4 ns |
| of which growth | 11.6 ns | **9.1 ns** | 8.9 ns |

Steady state was already ahead and pre-sized was level, so neither the probe nor
its writes was the problem. Growth was: more than half of an insert for both
containers, and 2.7 ns per insert worse here. Inside it, `_rehash` recomputed
`hash()` for every entry it moved, where the stdlib reuses the hash it stores.

### The fix, and why it is affordable

A rehash does not need a whole hash. It needs the new slot, which is
`hash & new_mask` and so depends only on low bits, and the new tag, which it can
copy from the control byte the entry already had rather than recomputing it from
the top of the hash. So `caching_hashes` stores the low **32 bits** per entry,
not 64 -- half the memory of the first version, and slightly faster besides, for
the smaller array and the skipped tag computation.

It is now the default. Growth fell to 9.1 ns against the stdlib's 8.9, an insert
while growing to 19.1 against 19.4, corpus builds from ~1.3x to ~1.15x with
hebrew crossing over to a win, and whole-corpus word counting now wins on eleven
of twelve. It costs 4 bytes per entry, about 12% of a map: 59% of a `Dict`'s
footprint rather than 52%. `caching_hashes=False` gets the 52% back, and the
1.3x build with it.

**And the width follows `KeyCountType`,** because the two are the same question.
A rehash needs as many hash bits as the capacity has, and `KeyCountType` is what
caps the capacity: a `uint16` index allows 65535 entries, whose table never
exceeds 2^17 slots. So a `uint16` map caches 16 bits, not 32, and `_rehash`
falls back to hashing only for the single doubling past 65536 slots -- a branch
reachable between 57344 and 65535 entries, and tested there.

`StringDict[V, .uint16]` is therefore 12% smaller than the default across the
corpora, 4-7 bytes an entry, at **no measurable cost in time**. At 51% of a
`Dict` it beats turning the cache off while keeping the build speed the cache
buys, and it is the right configuration for any dictionary that will not reach
65535 keys.

### Does the cache pay on a small map?

A map of twenty entries rehashes twice, so there is almost nothing for a hash
cache to save, and turning it off looked like the obvious economy. It is not.
On the per-document workload, one configuration per process:

| configuration | ns per 20-word document | footprint |
| --- | --- | --- |
| `uint32` + cache (default) | 573 | 712 B |
| `uint16` + cache | 571 | 600 B |
| `uint8` + cache | 582 | 568 B |
| `uint32`, cache off | 642 | 616 B |
| `uint8`, cache off | 613 | 520 B |

The cache is worth 11% even here -- 565/573/585 against 641/643/652 over three
pairs -- which is more than the two rehashes' worth of hashing can explain on
its own. With the cache off, `_rehash` does not merely hash again; it rebuilds
each key's slice from the offset array first, and that is the larger half.

And narrowing the index saves more memory than dropping the cache does, for
nothing: `uint8` with the cache is both smaller and faster than `uint32`
without it. The parameter to reach for first, on a map whose size is known, is
`KeyCountType`.

### A note on measuring this one

The first comparison ran both index widths in one process and reported lookups
3% slower on `uint16`, which was then written up as the cost of widening a
16-bit index on every probe. That explanation was invented, and the number was
noise: a second run of the same benchmark had `uint16` faster on every row. A
third, comparing builds, showed `uint16` 10-28% *faster* -- also noise, from a
cold first invocation.

Measured one width per process and repeated, both build and lookup are level.
There is no widening cost to explain: a 16-bit load zero-extends in the same
instruction as a 32-bit one. This is the third time in this container's history
that an in-process comparison has produced a confident wrong answer, after the
cached-hash ordering and the `destructive` build figures. Anything allocator- or
cache-sensitive gets one variant per process here.

The first version of this stored the full 64-bit hash and was worth only 1.4 ns
per insert, against a predicted 2.4. Narrowing it to 32 bits and taking the tag
from the old control byte is worth 2.3 -- more saving for half the memory,
because the extra work was never in the hashing alone.

### What is left, which is not growth

Corpus builds remain ~1.15x, and part of that is structural: a `StringDict`
copies each key's bytes into its packed buffer, while a `Dict` stores a
copy-on-write alias and copies nothing at all. That is the price of the density,
and it shows on the CJK rows where the stdlib gets 500 bytes per key for free.
The compensation is that the source strings can then be dropped, where a `Dict`
pins every one of their allocations.

The constructor is also still behind -- 38.5 ns against a `Dict`'s 0.3, which
allocates nothing until its first insert. The allocation work below covers why
deferral is the wrong answer here and a cheaper constructor was the right one.

### Fixed on the way: the tombstone mask check cost 19% of an insert

`destructive=True` is the default, and it used to make inserts 19% slower than
`destructive=False` (25.2 ns against 20.3 at 28000 keys). The bit itself was
never the problem. `_reserve_deleted_bit` was `@no_inline` and did its bounds
check *inside* the function, so every insert paid for a call to learn that the
mask was already big enough. Hoisting the check into the caller and leaving only
the reallocation behind `@no_inline` took the insert to 19.7 ns, level with the
non-destructive variant. Deletion support now costs one bit per entry and no
measurable time.

### Killed by measurement: splitting the growth path out of `KeysContainer.add`

The key-byte buffer grows inside `_append_key`, whose body is a few instructions
around a `memcpy`. In `mm_lcrs_tree` exactly that shape cost 20%, and splitting
the cold path into an `@no_inline` helper took a node from 5.8 ns to 3.4.

The same split here is consistently **2-3% slower**. The difference is where the
cheap check already sat: in `_reserve_deleted_bit` the hot path was a function
call; here it was already inline, so the split only added a call and register
spills at the growth site. Reverted.

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
