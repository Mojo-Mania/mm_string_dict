# Improvements

Open items, most worthwhile first. Numbers are release builds
(`-D ASSERT=none`).

## 1. Inserts are ~16% behind the stdlib `Dict`

19.5 ns against 16.8 for 20000 twelve-byte keys, measured one variant per
process. Lookups are level now; inserts are not. Worth profiling before
guessing: candidates are the two group scans `put` does (one for an existing
key, one for a free slot), appending into three growable regions, and the
tombstone-mask growth check on every insert.

## 2. Deleted entries still hold their key bytes and value

A deleted entry's slot is reclaimed -- `_rehash` drops tombstones and an insert
can take a deleted slot -- but its key bytes stay in the packed buffer and its
value stays in the list, because entries are addressed by a dense index that
nothing renumbers. A map that churns therefore grows in key storage even though
the table does not.

`_rehash` is the place to fix it: it already visits every live entry, so it
could compact the key buffer and the value list at the same time and renumber
the slots it is rebuilding anyway. The cost is that any `StringSlice` a caller
is holding into the key buffer would be invalidated.

## 3. Values sit in a `List`, keys do not

The keys avoid a per-entry allocation; the values do not avoid a `List`. That
is fine in itself, but it means a map owns four growable regions that grow
independently -- keys, key offsets, values, and the slot table. Holding them in
one allocation, the way `mm_fiby_tree` and `mm_lcrs_tree` do, would cut the
allocation count per map and shrink the handle.

## 4. Smaller items

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
