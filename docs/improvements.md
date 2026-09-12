# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Tombstones are never reclaimed

`delete` marks an entry dead in a bitmask; its slot, its key bytes and its
value all stay. Nothing ever reclaims them, so a map that churns grows without
bound — the table doubles because occupied slots keep rising, even though the
live count does not.

`_rehash` is the natural place to fix it: it already walks every slot and
rebuilds the table, so it could skip deleted entries and compact the key buffer
and value list at the same time. The catch is that compacting renumbers key
indices, so every slot that survives has to be renumbered with them, and any
`StringSlice` a caller is holding into the key buffer is invalidated.

## 2. Lookups are slower than the stdlib `Dict`

16.8 ns against 12.8 for a present key, 5.6 against 3.7 for an absent one.
Probing is a plain scalar loop over `slot_to_index`, one slot at a time, with a
dependent load per step. The stdlib set and dict use SIMD probing over a group
of slots at once, which is where most of that gap probably lives.

Worth measuring before building: the cached hash already rejects most
mismatches without touching the key bytes, so the win may be smaller than it
looks.

## 3. Values sit in a `List`, keys do not

The keys avoid a per-entry allocation; the values do not avoid a `List`, which
is fine, but it does mean `StringDict` owns three growable regions that grow
independently. Holding them in one allocation, the way `mm_fiby_tree` and
`mm_lcrs_tree` do, would cut the allocation count per map and shrink the
handle.

## 4. Smaller items

- **No iteration.** There is no way to walk the entries; `keys_vec()` returns
  the keys, but nothing pairs them with values. An `items()` iterator yielding
  `(StringSlice, ref V)` would be the natural addition, and would have to skip
  tombstoned entries.
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
