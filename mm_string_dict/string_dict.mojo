"""A hash map from string keys to arbitrary values, stored compactly.

The keys do not live in individual `String`s. They are appended end to end into
one byte buffer, with a parallel array of end offsets, so a key costs its bytes
plus one offset -- no per-key allocation, no per-key header. Lookups compare
against slices of that buffer.

The map itself is open addressing with linear probing over a power-of-two slot
array. A slot holds a one-based index into the key and value arrays, so zero
means "empty" and no separate occupancy bitmap is needed.

```mojo
from mm_string_dict import StringDict

var counts = StringDict[Int]()
counts.put("apple", 1)
counts.put("pear", 2)
print(counts.get("apple", 0))   # 1
print("pear" in counts)         # True
```

Four compile-time parameters trade memory for capability; see `StringDict`.
"""

from std.bit import bit_width, pop_count
from std.memory import unsafe_memcpy, unsafe_memset_zero
from std.memory.alloc import Allocation, alloc, dealloc


comptime _MIN_KEYS = 8
"""The smallest key capacity a `KeysContainer` will allocate."""


struct KeysContainer[KeyEndType: DType = .uint32](ImplicitlyCopyable, Sized):
    """Stores many strings in one byte buffer, addressed by index.

    Keys are appended end to end and delimited by a parallel array of end
    offsets, so key `i` occupies `keys[end[i - 1] .. end[i]]`. That costs one
    offset per key instead of a `String` header and an allocation each.

    Parameters:
        KeyEndType: The unsigned integer type holding the end offsets. It caps
            the total size of all keys together: `uint32` allows 4GB of them.
    """

    var keys: Pointer[UInt8, MutUntrackedOrigin]
    """The bytes of every key, one after another."""
    var allocated_bytes: Int
    """How many bytes `keys` can hold."""
    var keys_end: Pointer[Scalar[Self.KeyEndType], MutUntrackedOrigin]
    """Where each key ends in `keys`."""
    var count: Int
    """How many keys are stored."""
    var capacity: Int
    """How many end offsets `keys_end` can hold."""

    def __init__(out self, capacity: Int):
        """Constructs a container with room for `capacity` keys.

        Args:
            capacity: The number of keys to reserve offsets for. The byte
                buffer starts at eight times that, and grows as needed.
        """
        comptime assert (
            Self.KeyEndType == .uint8
            or Self.KeyEndType == .uint16
            or Self.KeyEndType == .uint32
            or Self.KeyEndType == .uint64
        ), "KeyEndType needs to be an unsigned integer"
        # Below this, growth cannot make progress: the offset array grows by
        # half, which rounds to nothing at one, and the byte buffer grows by
        # half of zero.
        var slots = capacity if capacity > _MIN_KEYS else _MIN_KEYS
        self.allocated_bytes = slots << 3
        self.keys = alloc[UInt8]({count = self.allocated_bytes}).unsafe_leak()
        self.keys_end = alloc[Scalar[Self.KeyEndType]](
            {count = slots}
        ).unsafe_leak()
        self.count = 0
        self.capacity = slots

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy.

        Args:
            copy: The container to duplicate.
        """
        self.allocated_bytes = copy.allocated_bytes
        self.count = copy.count
        self.capacity = copy.capacity
        self.keys = alloc[UInt8]({count = self.allocated_bytes}).unsafe_leak()
        unsafe_memcpy(dest=self.keys, src=copy.keys, count=self.allocated_bytes)
        self.keys_end = alloc[Scalar[Self.KeyEndType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self.keys_end, src=copy.keys_end, count=self.capacity
        )

    def __deinit__(deinit self):
        """Releases both buffers."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.keys,
                layout={count = self.allocated_bytes},
            )
        )
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.keys_end, layout={count = self.capacity}
            )
        )

    @always_inline
    def add(mut self, key: StringSlice):
        """Appends a key, growing either buffer if it has to.

        Args:
            key: The key to store. Its bytes are copied.
        """
        var prev_end = (
            0 if self.count
            == 0 else self.keys_end[unsafe_offset=self.count - 1]
        )
        var key_length = key.byte_length()
        var new_end = prev_end + Scalar[Self.KeyEndType](key_length)

        var old_allocated_bytes = self.allocated_bytes
        var needs_realocation = False
        while new_end > Scalar[Self.KeyEndType](self.allocated_bytes):
            self.allocated_bytes += self.allocated_bytes >> 1
            needs_realocation = True

        if needs_realocation:
            var keys = alloc[UInt8](
                {count = self.allocated_bytes}
            ).unsafe_leak()
            unsafe_memcpy(dest=keys, src=self.keys, count=Int(prev_end))
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.keys,
                    layout={count = old_allocated_bytes},
                )
            )
            self.keys = keys

        unsafe_memcpy(
            dest=self.keys.unsafe_offset(prev_end),
            src=Pointer(key.unsafe_ptr()),
            count=key_length,
        )
        var count = self.count + 1
        if count >= self.capacity:
            var new_capacity = self.capacity + (self.capacity >> 1)
            if new_capacity <= count:
                new_capacity = count + 1
            var keys_end = alloc[Scalar[Self.KeyEndType]](
                {count = new_capacity}
            ).unsafe_leak()
            unsafe_memcpy(dest=keys_end, src=self.keys_end, count=self.capacity)
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.keys_end,
                    layout={count = self.capacity},
                )
            )
            self.keys_end = keys_end
            self.capacity = new_capacity

        self.keys_end.unsafe_store(self.count, new_end)
        self.count = count

    @always_inline
    def get(self, index: Int) -> StringSlice[ImmOrigin(origin_of(self))]:
        """Returns the key at `index`, or an empty slice if out of range.

        Args:
            index: The key index.

        Returns:
            A slice borrowing the container's byte buffer.
        """
        var keys_ptr = self.keys.as_imm().unsafe_origin_cast[origin_of(self)]()
        if index < 0 or index >= self.count:
            return StringSlice(
                unsafe_from_utf8=Span(unsafe_ptr=keys_ptr, length=0)
            )
        var start = 0 if index == 0 else Int(
            self.keys_end[unsafe_offset=index - 1]
        )
        var length = Int(self.keys_end[unsafe_offset=index]) - start
        return StringSlice(
            unsafe_from_utf8=Span(
                unsafe_ptr=keys_ptr.unsafe_offset(start), length=length
            )
        )

    @always_inline
    def clear(mut self):
        """Forgets every key, keeping the allocated buffers."""
        self.count = 0

    @always_inline
    def __getitem__(
        self, index: Int
    ) -> StringSlice[ImmOrigin(origin_of(self))]:
        """Returns the key at `index`.

        Args:
            index: The key index.

        Returns:
            A slice borrowing the container's byte buffer.
        """
        return self.get(index)

    @always_inline
    def __len__(self) -> Int:
        """Returns how many keys are stored.

        Returns:
            The key count.
        """
        return self.count

    def keys_vec(self, out result: List[StringSlice[origin_of(self)]]):
        """Returns every key as a list of slices.

        Args:
            result: The list to build, named for the return type.
        """
        var keys = type_of(result)(capacity=self.count)
        for i in range(self.count):
            keys.append(self[i])
        return keys^

    def print_keys(self):
        """Prints every key, for debugging."""
        print("(" + String(self.count) + ")[", end="")
        for i in range(self.count):
            var end = ", " if i < self.count - 1 else ""
            print(self[i], end=end)
        print("]")


struct StringDict[
    V: Copyable & Deinitable,
    KeyCountType: DType = .uint32,
    KeyOffsetType: DType = .uint32,
    destructive: Bool = True,
    caching_hashes: Bool = True,
](Copyable, Movable, Sized):
    """A hash map from string keys to `V`, with the keys packed end to end.

    Parameters:
        V: The value type.
        KeyCountType: The unsigned integer type indexing keys and slots. It
            caps the number of entries: `uint16` allows 65535 and halves the
            slot array, `uint32` allows four billion.
        KeyOffsetType: The unsigned integer type holding key end offsets, which
            caps the total size of all keys together.
        destructive: Whether `delete` is supported. It costs one bit per entry
            for the tombstone mask; with it off, `delete` does nothing.
        caching_hashes: Whether to store each key's hash next to its slot. It
            costs `KeyCountType` bytes per slot and saves rehashing the key on
            every probe, which is worth it unless keys are very short.
    """

    var keys: KeysContainer[Self.KeyOffsetType]
    """The keys, packed end to end."""
    var key_hashes: Pointer[Scalar[Self.KeyCountType], MutUntrackedOrigin]
    """Cached hash per slot, when `caching_hashes` is on."""
    var values: List[Self.V]
    """The values, in insertion order, parallel to the keys."""
    var slot_to_index: Pointer[Scalar[Self.KeyCountType], MutUntrackedOrigin]
    """One-based key index per slot; zero means the slot is empty."""
    var deleted_mask: Pointer[UInt8, MutUntrackedOrigin]
    """One bit per entry marking it deleted, when `destructive` is on."""
    var count: Int
    """How many live entries the map holds."""
    var capacity: Int
    """How many slots the table has. Always a power of two."""

    def __init__(out self, capacity: Int = 16):
        """Constructs an empty map.

        Args:
            capacity: Slots to reserve, rounded up to a power of two, minimum
                eight.
        """
        comptime assert (
            Self.KeyCountType == .uint8
            or Self.KeyCountType == .uint16
            or Self.KeyCountType == .uint32
            or Self.KeyCountType == .uint64
        ), "KeyCountType needs to be an unsigned integer"
        self.count = 0
        if capacity <= 8:
            self.capacity = 8
        else:
            var icapacity = Int64(capacity)
            self.capacity = capacity if pop_count(icapacity) == 1 else 1 << Int(
                bit_width(icapacity)
            )
        self.keys = KeysContainer[Self.KeyOffsetType](self.capacity)

        comptime if Self.caching_hashes:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = self.capacity}
            ).unsafe_leak()
        else:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = 0}
            ).unsafe_leak()
        self.values = List[Self.V](capacity=capacity)
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memset_zero(self.slot_to_index, self.capacity)

        comptime if Self.destructive:
            self.deleted_mask = alloc[UInt8](
                {count = self.capacity >> 3}
            ).unsafe_leak()
            unsafe_memset_zero(self.deleted_mask, self.capacity >> 3)
        else:
            self.deleted_mask = alloc[UInt8]({count = 0}).unsafe_leak()

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy.

        Args:
            copy: The map to duplicate.
        """
        self.count = copy.count
        self.capacity = copy.capacity
        self.keys = copy.keys

        comptime if Self.caching_hashes:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = self.capacity}
            ).unsafe_leak()
            unsafe_memcpy(
                dest=self.key_hashes,
                src=copy.key_hashes,
                count=self.capacity,
            )
        else:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = 0}
            ).unsafe_leak()
        self.values = copy.values.copy()
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self.slot_to_index,
            src=copy.slot_to_index,
            count=self.capacity,
        )

        comptime if Self.destructive:
            self.deleted_mask = alloc[UInt8](
                {count = self.capacity >> 3}
            ).unsafe_leak()
            unsafe_memcpy(
                dest=self.deleted_mask,
                src=copy.deleted_mask,
                count=self.capacity >> 3,
            )
        else:
            self.deleted_mask = alloc[UInt8]({count = 0}).unsafe_leak()

    def __init__(out self, *, deinit move: Self):
        """Takes over `move`'s storage.

        Args:
            move: The map to move from.
        """
        self.keys = move.keys^
        self.key_hashes = move.key_hashes
        self.values = move.values^
        self.slot_to_index = move.slot_to_index
        self.deleted_mask = move.deleted_mask
        self.count = move.count
        self.capacity = move.capacity

    def __deinit__(deinit self):
        """Releases the slot array and the optional side tables."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.slot_to_index,
                layout={count = self.capacity},
            )
        )
        comptime if Self.destructive:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.deleted_mask,
                    layout={count = self.capacity >> 3},
                )
            )
        else:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.deleted_mask, layout={count = 0}
                )
            )
        comptime if Self.caching_hashes:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.key_hashes,
                    layout={count = self.capacity},
                )
            )
        else:
            dealloc(
                Allocation(unsafe_owned_ptr=self.key_hashes, layout={count = 0})
            )

    def __len__(self) -> Int:
        """Returns how many live entries the map holds.

        Returns:
            The entry count.
        """
        return self.count

    @always_inline
    def __contains__(self, key: StringSlice) -> Bool:
        """Returns whether `key` is present and not deleted.

        Args:
            key: The key to look for.

        Returns:
            True if the map holds a live entry for it.
        """
        var key_index = self._find_key_index(key)
        if key_index == 0:
            return False
        comptime if Self.destructive:
            if self._is_deleted(key_index - 1):
                return False
        return True

    def put(mut self, key: StringSlice, value: Self.V):
        """Inserts `key`, or replaces the value if it is already present.

        Args:
            key: The key to insert. Its bytes are copied.
            value: The value to associate with it.
        """
        if self.keys.count >= self.capacity - (self.capacity >> 3):
            self._rehash()

        var key_hash = hash(key).cast[Self.KeyCountType]()
        var modulo_mask = self.capacity - 1
        var slot = Int(key_hash & Scalar[Self.KeyCountType](modulo_mask))
        while True:
            var key_index = Int(self.slot_to_index.unsafe_load(slot))
            if key_index == 0:
                self.keys.add(key)

                comptime if Self.caching_hashes:
                    self.key_hashes.unsafe_store(slot, key_hash)
                self.values.append(value.copy())
                self.count += 1
                self.slot_to_index.unsafe_store(
                    slot, Scalar[Self.KeyCountType](self.keys.count)
                )
                return

            comptime if Self.caching_hashes:
                var other_key_hash = self.key_hashes[unsafe_offset=slot]
                if other_key_hash == key_hash:
                    var other_key = self.keys[key_index - 1]
                    if other_key == key:
                        # replace value
                        self.values[key_index - 1] = value.copy()

                        comptime if Self.destructive:
                            if self._is_deleted(key_index - 1):
                                self.count += 1
                                self._not_deleted(key_index - 1)
                        return
            else:
                var other_key = self.keys[key_index - 1]
                if other_key == key:
                    # replace value
                    self.values[key_index - 1] = value.copy()

                    comptime if Self.destructive:
                        if self._is_deleted(key_index - 1):
                            self.count += 1
                            self._not_deleted(key_index - 1)
                    return

            slot = (slot + 1) & modulo_mask

    @always_inline
    def _is_deleted(self, index: Int) -> Bool:
        var offset = index >> 3
        var bit_index = index & 7
        return (
            self.deleted_mask.unsafe_offset(offset).unsafe_load()
            & UInt8(1 << bit_index)
            != 0
        )

    @always_inline
    def _deleted(self, index: Int):
        var offset = index >> 3
        var bit_index = index & 7
        var p = self.deleted_mask.unsafe_offset(offset)
        var mask = p.unsafe_load()
        p.unsafe_store(mask | UInt8((1 << bit_index)))

    @always_inline
    def _not_deleted(self, index: Int):
        var offset = index >> 3
        var bit_index = index & 7
        var p = self.deleted_mask.unsafe_offset(offset)
        var mask = p.unsafe_load()
        p.unsafe_store(mask & UInt8(~(1 << bit_index)))

    @always_inline
    def _rehash(mut self):
        var old_slot_to_index = self.slot_to_index
        var old_capacity = self.capacity
        self.capacity <<= 1
        var mask_capacity = self.capacity >> 3
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memset_zero(self.slot_to_index, self.capacity)

        var key_hashes = self.key_hashes

        comptime if Self.caching_hashes:
            key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = self.capacity}
            ).unsafe_leak()

        comptime if Self.destructive:
            var deleted_mask = alloc[UInt8](
                {count = mask_capacity}
            ).unsafe_leak()
            unsafe_memset_zero(deleted_mask, mask_capacity)
            unsafe_memcpy(
                dest=deleted_mask,
                src=self.deleted_mask,
                count=old_capacity >> 3,
            )
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.deleted_mask,
                    layout={count = old_capacity >> 3},
                )
            )
            self.deleted_mask = deleted_mask

        var modulo_mask = self.capacity - 1
        for i in range(old_capacity):
            if old_slot_to_index[unsafe_offset=i] == 0:
                continue
            var key_hash: Scalar[Self.KeyCountType]

            comptime if Self.caching_hashes:
                key_hash = self.key_hashes[unsafe_offset=i]
            else:
                key_hash = hash(
                    self.keys[Int(old_slot_to_index[unsafe_offset=i] - 1)]
                ).cast[Self.KeyCountType]()

            var slot = Int(key_hash & Scalar[Self.KeyCountType](modulo_mask))

            while True:
                var key_index = Int(self.slot_to_index.unsafe_load(slot))

                if key_index == 0:
                    self.slot_to_index.unsafe_store(
                        slot, old_slot_to_index[unsafe_offset=i]
                    )
                    break
                else:
                    slot = (slot + 1) & modulo_mask

            comptime if Self.caching_hashes:
                key_hashes[unsafe_offset=slot] = key_hash

        comptime if Self.caching_hashes:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.key_hashes,
                    layout={count = old_capacity},
                )
            )
            self.key_hashes = key_hashes
        dealloc(
            Allocation(
                unsafe_owned_ptr=old_slot_to_index,
                layout={count = old_capacity},
            )
        )

    def get(self, key: StringSlice, default: Self.V) -> Self.V:
        """Returns the value for `key`, or `default` if it is not there.

        Args:
            key: The key to look up.
            default: What to return when the key is absent or deleted.

        Returns:
            The stored value, or `default`.
        """
        var key_index = self._find_key_index(key)
        if key_index == 0:
            return default.copy()

        comptime if Self.destructive:
            if self._is_deleted(key_index - 1):
                return default.copy()
        return self.values[key_index - 1].copy()

    def delete(mut self, key: StringSlice):
        """Removes `key`, if `destructive` is on and the key is present.

        The entry is tombstoned rather than removed: its slot and its key bytes
        stay, and re-inserting the same key revives it.

        Args:
            key: The key to remove.
        """
        comptime if not Self.destructive:
            return

        var key_index = self._find_key_index(key)
        if key_index == 0:
            return
        if not self._is_deleted(key_index - 1):
            self.count -= 1
        self._deleted(key_index - 1)

    def upsert(
        mut self,
        key: StringSlice,
        update: def(value: Optional[Self.V]) thin -> Self.V,
    ):
        """Inserts or updates `key` with a function of the current value.

        `update` is called with `None` when the key is absent, and with the
        current value when it is present, which saves looking the key up twice.

        Args:
            key: The key to insert or update.
            update: Called to produce the new value.
        """
        var key_index = self._find_key_index(key)
        if key_index == 0:
            var value = update(None)
            self.put(key, value)
        else:
            key_index -= 1

            comptime if Self.destructive:
                if self._is_deleted(key_index):
                    self.count += 1
                    self._not_deleted(key_index)
                    self.values[key_index] = update(None)
                    return

            self.values[key_index] = update(self.values[key_index].copy())

    def clear(mut self):
        """Removes every entry, keeping the allocated storage."""
        self.values.clear()
        self.keys.clear()
        unsafe_memset_zero(self.slot_to_index, self.capacity)

        comptime if Self.destructive:
            unsafe_memset_zero(self.deleted_mask, self.capacity >> 3)
        self.count = 0

    @always_inline
    def _find_key_index(self, key: StringSlice) -> Int:
        var key_hash = hash(key).cast[Self.KeyCountType]()
        var modulo_mask = self.capacity - 1

        var slot = Int(key_hash & Scalar[Self.KeyCountType](modulo_mask))
        while True:
            var key_index = Int(self.slot_to_index.unsafe_load(slot))
            if key_index == 0:
                return key_index

            comptime if Self.caching_hashes:
                var other_key_hash = self.key_hashes[unsafe_offset=slot]
                if key_hash == other_key_hash:
                    var other_key = self.keys[key_index - 1]
                    if other_key == key:
                        return key_index
            else:
                var other_key = self.keys[key_index - 1]
                if other_key == key:
                    return key_index

            slot = (slot + 1) & modulo_mask
