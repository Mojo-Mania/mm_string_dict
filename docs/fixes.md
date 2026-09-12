# Fixes applied while packaging

The implementation is unchanged apart from the imports it needed and the three
problems below, each of which now has a regression test.

## 1. Delete-heavy churn spun forever

`put` decided when to grow the table from the live entry count:

```mojo
if self.count >= self.capacity - (self.capacity >> 3):
    self._rehash()
```

`delete` decrements `count`, but it does not free the slot — the entry is
tombstoned and its slot stays occupied. So a map that has entries deleted and
new ones added keeps filling slots while `count` says there is room. Once every
slot is occupied, the probe loop in `put` looks for an empty slot that no
longer exists, and never returns.

Reproduced by inserting 100 keys, deleting all 100, then inserting 200 more:
the process hung at "slots used 101 / 128" and had to be killed.

The trigger now counts occupied slots, which is `self.keys.count`:

```mojo
if self.keys.count >= self.capacity - (self.capacity >> 3):
```

Tombstoned entries are still never reclaimed, so a long churn grows the table
rather than reusing the space. Compacting during `_rehash` would fix that and is
listed in [`improvements.md`](improvements.md).

Covered by `test_delete_heavy_churn_terminates`.

## 2. A key capacity of one corrupted the heap

`KeysContainer` grows its offset array by half:

```mojo
var new_capacity = self.capacity + (self.capacity >> 1)
```

At a capacity of one that is `1 + 0`, so it never grows, and the next
`keys_end.unsafe_store(self.count, ...)` writes past the end of the allocation.
A capacity of zero is worse: `allocated_bytes` is zero, and the byte-buffer
growth loop adds half of zero forever.

`StringDict` passed its constructor argument straight through, so
`StringDict[Int](capacity=1)` crashed in the allocator.

Two changes: the container clamps its capacity to eight, below which growth
cannot make progress, and the growth step is floored so it always increases.
The dict now also hands the container its rounded capacity rather than the raw
argument.

Covered by `test_small_initial_capacity` and
`test_keys_container_grows_its_byte_buffer`.

## 3. A deleted key still reported as present

`__contains__` was:

```mojo
return self._find_key_index(key) != 0
```

which finds tombstoned entries too, so `"apple" in dict` was `True` while
`dict.get("apple", -1)` returned `-1`. It now checks the tombstone mask, as
`get` does.

Covered by `test_delete`.

## Also

`StringDict` now conforms to `Copyable` and `Movable`. It had a copy
constructor already but did not declare the conformance, so `.copy()` was not
available and the type could not be moved out of a function. The move
constructor is explicit because the type has a custom `__deinit__`.

The non-destructive and non-caching branches now allocate and free
symmetrically. Before, the zero-sized allocations made in `__init__` were never
released, and the copy constructor left those fields dangling instead — neither
crashes, but the asymmetry made the lifetime hard to reason about.
