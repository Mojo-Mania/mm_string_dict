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
from std.memory import unsafe_memcpy, unsafe_memset, unsafe_memset_zero
from std.memory.alloc import Allocation, alloc, dealloc
from std.sys.info import simd_width_of


comptime GROUP = simd_width_of[DType.uint8]()
"""How many slots one SIMD compare covers, chosen for the target: 16 with
NEON, 32 with AVX2, 64 with AVX-512."""


def _lane_indices() -> SIMD[DType.uint8, GROUP]:
    """0, 1, 2, ... one per lane, for picking the lowest set lane.

    Returns:
        A vector of lane numbers.
    """
    var indices = SIMD[DType.uint8, GROUP](0)
    comptime for lane in range(GROUP):
        indices[lane] = UInt8(lane)
    return indices


comptime _LANE_INDICES = _lane_indices()
"""Lane numbers, built once at compile time."""

comptime _EMPTY: UInt8 = 0x80
"""Control byte for a slot that has never held an entry. A probe stops here."""
comptime _DELETED: UInt8 = 0xFE
"""Control byte for a slot whose entry was deleted. A probe walks past it, and
an insert may reuse it."""


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
    caching_hashes: Bool = False,
](Boolable, Copyable, Movable, Sized):
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
        caching_hashes: Whether to store each key's full hash beside its slot,
            as a second filter after the control byte's seven bits. Off by
            default: the tag already rejects 127 of every 128 non-matching
            slots, so this buys a few percent on lookups and costs
            `KeyCountType` bytes per slot -- and footprint is what this
            container is for. Inserts measure the same either way. Turn it on
            when keys are long and share prefixes, where a false positive
            means an expensive comparison.
    """

    var _keys: KeysContainer[Self.KeyOffsetType]
    """The keys, packed end to end. Reachable through `key_storage()`."""
    var control: Pointer[UInt8, MutUntrackedOrigin]
    """One byte per slot: `_EMPTY`, `_DELETED`, or the top seven bits of the
    key's hash. `GROUP` of them are compared at once, and the first `GROUP`
    bytes are mirrored past the end so a load near the end stays in bounds."""
    var key_hashes: Pointer[Scalar[Self.KeyCountType], MutUntrackedOrigin]
    """Cached hash per slot, when `caching_hashes` is on."""
    var _values: List[Self.V]
    """The values, in insertion order, parallel to the keys."""
    var slot_to_index: Pointer[Scalar[Self.KeyCountType], MutUntrackedOrigin]
    """One-based key index per slot; zero means the slot is empty."""
    var deleted_mask: Pointer[UInt8, MutUntrackedOrigin]
    """One bit per entry marking it deleted, when `destructive` is on."""
    var deleted_bytes: Int
    """Bytes allocated for `deleted_mask`. It is indexed by entry, not by slot:
    reusing a deleted slot still appends a new entry, so entries outgrow the
    table and the mask has to track them, not it."""
    var count: Int
    """How many live entries the map holds."""
    var occupied: Int
    """Slots that are not `_EMPTY`, deleted ones included. This is what the
    growth check looks at: a deleted slot is not reusable by a probe that has
    already walked past it, so it still costs the table room."""
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
        self.occupied = 0
        if capacity <= GROUP:
            self.capacity = GROUP
        else:
            var icapacity = Int64(capacity)
            self.capacity = capacity if pop_count(icapacity) == 1 else 1 << Int(
                bit_width(icapacity)
            )
        self._keys = KeysContainer[Self.KeyOffsetType](self.capacity)

        comptime if Self.caching_hashes:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = self.capacity}
            ).unsafe_leak()
        else:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = 0}
            ).unsafe_leak()
        self._values = List[Self.V](capacity=capacity)
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        self.control = alloc[UInt8](
            {count = self.capacity + GROUP}
        ).unsafe_leak()
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)

        comptime if Self.destructive:
            self.deleted_bytes = self.capacity >> 3
            self.deleted_mask = alloc[UInt8](
                {count = self.deleted_bytes}
            ).unsafe_leak()
            unsafe_memset_zero(self.deleted_mask, self.deleted_bytes)
        else:
            self.deleted_bytes = 0
            self.deleted_mask = alloc[UInt8]({count = 0}).unsafe_leak()

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy.

        Args:
            copy: The map to duplicate.
        """
        self.count = copy.count
        self.occupied = copy.occupied
        self.capacity = copy.capacity
        self._keys = copy._keys
        self.control = alloc[UInt8](
            {count = self.capacity + GROUP}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self.control, src=copy.control, count=self.capacity + GROUP
        )

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
        self._values = copy._values.copy()
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self.slot_to_index,
            src=copy.slot_to_index,
            count=self.capacity,
        )

        comptime if Self.destructive:
            self.deleted_bytes = copy.deleted_bytes
            self.deleted_mask = alloc[UInt8](
                {count = self.deleted_bytes}
            ).unsafe_leak()
            unsafe_memcpy(
                dest=self.deleted_mask,
                src=copy.deleted_mask,
                count=self.deleted_bytes,
            )
        else:
            self.deleted_bytes = 0
            self.deleted_mask = alloc[UInt8]({count = 0}).unsafe_leak()

    def __init__(out self, *, deinit move: Self):
        """Takes over `move`'s storage.

        Args:
            move: The map to move from.
        """
        self._keys = move._keys^
        self.control = move.control
        self.key_hashes = move.key_hashes
        self._values = move._values^
        self.slot_to_index = move.slot_to_index
        self.deleted_mask = move.deleted_mask
        self.deleted_bytes = move.deleted_bytes
        self.count = move.count
        self.occupied = move.occupied
        self.capacity = move.capacity

    def __deinit__(deinit self):
        """Releases the slot array and the optional side tables."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.slot_to_index,
                layout={count = self.capacity},
            )
        )
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.control,
                layout={count = self.capacity + GROUP},
            )
        )
        comptime if Self.destructive:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self.deleted_mask,
                    layout={count = self.deleted_bytes},
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
        return self._find_slot(key) != -1

    def key_bytes(self) -> Int:
        """Returns how many bytes are allocated for the packed key buffer.

        Returns:
            The size of the key buffer, which holds every key's bytes end to
            end -- live and deleted alike.
        """
        return self._keys.allocated_bytes

    def print_keys(self):
        """Prints every stored key, live or deleted, for debugging."""
        self._keys.print_keys()

    def __bool__(self) -> Bool:
        """Returns whether the map holds any live entry.

        Returns:
            True if it is non-empty.
        """
        return self.count != 0

    def __getitem__(self, key: StringSlice) raises -> Self.V:
        """Returns the value for `key`, raising if it is not there.

        Args:
            key: The key to look up.

        Raises:
            Error: When the key is absent or deleted. Use `get` for a default.

        Returns:
            The stored value.
        """
        var key_index = self._find_key_index(key)
        if key_index != 0:
            return self._values[key_index - 1].copy()
        raise Error("KeyError: ", key)

    def __setitem__(mut self, key: StringSlice, value: Self.V):
        """Inserts `key`, or replaces the value if it is already present.

        Args:
            key: The key to insert. Its bytes are copied.
            value: The value to associate with it.
        """
        self.put(key, value)

    def setdefault(mut self, key: StringSlice, default: Self.V) -> Self.V:
        """Returns the value for `key`, inserting `default` if it is absent.

        Args:
            key: The key to look up or insert.
            default: The value to insert when the key is absent.

        Returns:
            The value the map holds for `key` afterwards.
        """
        var key_index = self._find_key_index(key)
        if key_index != 0:
            return self._values[key_index - 1].copy()
        self.put(key, default)
        return default.copy()

    def pop(mut self, key: StringSlice) raises -> Self.V:
        """Removes `key` and returns its value, raising if it is not there.

        Args:
            key: The key to remove.

        Raises:
            Error: When the key is absent, or when `destructive` is off and the
                entry therefore cannot be removed.

        Returns:
            The value that was stored.
        """
        comptime if not Self.destructive:
            raise Error(
                "pop needs a destructive StringDict; this one cannot delete"
            )
        else:
            var slot = self._find_slot(key)
            if slot == -1:
                raise Error("KeyError: ", key)
            var key_index = Int(self.slot_to_index.unsafe_load(slot))
            var value = self._values[key_index - 1].copy()
            self._remove_at(slot)
            return value^

    def pop(mut self, key: StringSlice, default: Self.V) -> Self.V:
        """Removes `key` and returns its value, or `default` if it is absent.

        Args:
            key: The key to remove.
            default: What to return when the key is not there.

        Returns:
            The value that was stored, or `default`.
        """
        comptime if not Self.destructive:
            return default.copy()
        else:
            var slot = self._find_slot(key)
            if slot == -1:
                return default.copy()
            var key_index = Int(self.slot_to_index.unsafe_load(slot))
            var value = self._values[key_index - 1].copy()
            self._remove_at(slot)
            return value^

    def update(mut self, other: Self):
        """Inserts every entry of `other`, replacing values that collide.

        Args:
            other: The map to copy entries from.
        """
        for index in range(other._keys.count):
            comptime if Self.destructive:
                if other._is_deleted(index):
                    continue
            self.put(other._keys[index], other._values[index])

    def keys(
        ref self,
    ) -> _KeysIter[
        Self.V,
        Self.KeyCountType,
        Self.KeyOffsetType,
        Self.destructive,
        Self.caching_hashes,
        origin_of(self),
    ]:
        """Returns an iterator over the live keys, in insertion order.

        Returns:
            An iterator yielding slices of the key buffer.
        """
        return {src = Pointer(to=self)}

    def values(
        ref self,
    ) -> _ValuesIter[
        Self.V,
        Self.KeyCountType,
        Self.KeyOffsetType,
        Self.destructive,
        Self.caching_hashes,
        origin_of(self),
    ]:
        """Returns an iterator over the live values, in insertion order.

        Values are yielded by reference, so nothing is copied.

        Returns:
            An iterator yielding references to the values.
        """
        return {src = Pointer(to=self)}

    def items(
        ref self,
    ) -> _ItemsIter[
        Self.V,
        Self.KeyCountType,
        Self.KeyOffsetType,
        Self.destructive,
        Self.caching_hashes,
        origin_of(self),
    ]:
        """Returns an iterator over the live entries, in insertion order.

        Each entry carries a `key` slice and a copy of the `value`; use
        `values()` when copying the value would be wasteful.

        Returns:
            An iterator yielding entries.
        """
        return {src = Pointer(to=self)}

    def __iter__(
        ref self,
    ) -> _KeysIter[
        Self.V,
        Self.KeyCountType,
        Self.KeyOffsetType,
        Self.destructive,
        Self.caching_hashes,
        origin_of(self),
    ]:
        """Returns an iterator over the live keys, like the stdlib `Dict`.

        Returns:
            An iterator yielding slices of the key buffer.
        """
        return {src = Pointer(to=self)}

    @always_inline
    def _next_live(self, index: Int) -> Int:
        """Returns the first live key index at or after `index`, else -1."""
        var current = index
        while current < self._keys.count:
            comptime if Self.destructive:
                if self._is_deleted(current):
                    current += 1
                    continue
            return current
        return -1

    def put(mut self, key: StringSlice, value: Self.V):
        """Inserts `key`, or replaces the value if it is already present.

        Args:
            key: The key to insert. Its bytes are copied.
            value: The value to associate with it.
        """
        if self.occupied >= self.capacity - (self.capacity >> 3):
            self._rehash()

        var key_hash = hash(key)
        var mask = self.capacity - 1
        var tag = SIMD[DType.uint8, GROUP](Self._tag(key_hash))
        var slot = Int(key_hash & UInt64(mask))
        var reusable = -1

        while True:
            var group = self.control.unsafe_offset(slot).unsafe_load[
                width=GROUP
            ]()

            # Does one of these slots already hold this key? Most groups hold
            # no candidate at all, and one reduce answers that.
            var matches = group.eq(tag)
            if matches.reduce_or():
                while True:
                    var lane = Self._first_lane(matches)
                    if lane == GROUP:
                        break
                    var candidate = (slot + lane) & mask
                    var key_index = Int(
                        self.slot_to_index.unsafe_load(candidate)
                    )
                    if self._matches(candidate, key_index, key, key_hash):
                        self._values[key_index - 1] = value.copy()
                        return
                    matches[lane] = False

            # Remember the first slot an insert could take. A free slot carries
            # the high bit, whether it is empty or deleted.
            if reusable == -1:
                var lane = Self._first_lane(
                    (group & SIMD[DType.uint8, GROUP](0x80)).eq(
                        SIMD[DType.uint8, GROUP](0x80)
                    )
                )
                if lane != GROUP:
                    reusable = (slot + lane) & mask

            # An empty slot ends the probe: the key is not in the table.
            if group.eq(SIMD[DType.uint8, GROUP](_EMPTY)).reduce_or():
                break
            slot = (slot + GROUP) & mask

        self._keys.add(key)
        self._values.append(value.copy())
        self._reserve_deleted_bit(self._keys.count - 1)
        self.count += 1
        if self.control[unsafe_offset=reusable] == _EMPTY:
            self.occupied += 1
        self._occupy(reusable, key_hash, self._keys.count)

    @always_inline
    @staticmethod
    def _tag(key_hash: UInt64) -> UInt8:
        """The seven hash bits kept in the control byte.

        They come from the opposite end of the hash to the bits that choose
        the slot, so the two are independent and the tag actually discriminates
        between the keys that land in one group.
        """
        return UInt8((key_hash >> 57) & 0x7F)

    @always_inline
    @staticmethod
    def _first_lane(mask: SIMD[DType.bool, GROUP]) -> Int:
        """Index of the lowest set lane, or `GROUP` when none is set.

        Three SIMD instructions rather than one extract per lane: on a target
        with no movemask, unrolling the extraction costs more than the group
        compare it was meant to exploit.
        """
        return Int(
            mask.select(
                _LANE_INDICES, SIMD[DType.uint8, GROUP](GROUP)
            ).reduce_min()
        )

    @always_inline
    def _matches(
        self, slot: Int, key_index: Int, key: StringSlice, key_hash: UInt64
    ) -> Bool:
        """Whether the entry at `slot` really is `key`, past the tag match."""
        comptime if Self.caching_hashes:
            if (
                self.key_hashes[unsafe_offset=slot]
                != key_hash.cast[Self.KeyCountType]()
            ):
                return False
        return self._keys[key_index - 1] == key

    @always_inline
    def _occupy(mut self, slot: Int, key_hash: UInt64, key_index: Int):
        """Writes an entry into a slot, control byte and mirror included."""
        self.slot_to_index.unsafe_store(
            slot, Scalar[Self.KeyCountType](key_index)
        )
        comptime if Self.caching_hashes:
            self.key_hashes.unsafe_store(
                slot, key_hash.cast[Self.KeyCountType]()
            )
        var tag = Self._tag(key_hash)
        self.control[unsafe_offset=slot] = tag
        if slot < GROUP:
            self.control[unsafe_offset=self.capacity + slot] = tag

    @always_inline
    def _vacate(mut self, slot: Int):
        """Marks a slot deleted: a probe walks past it, an insert may take it.
        """
        self.control[unsafe_offset=slot] = _DELETED
        if slot < GROUP:
            self.control[unsafe_offset=self.capacity + slot] = _DELETED

    @always_inline
    def _remove_at(mut self, slot: Int):
        """Tombstones the entry in `slot`.

        The control byte stops the slot matching any tag, so the key can no
        longer be found; the per-entry bit is what iteration consults, since it
        walks entries rather than slots.
        """
        comptime if Self.destructive:
            var key_index = Int(self.slot_to_index.unsafe_load(slot))
            self._deleted(key_index - 1)
            self._vacate(slot)
            self.count -= 1

    @always_inline
    def _reserve_deleted_bit(mut self, index: Int):
        """Makes sure the tombstone mask covers entry `index`.

        Only the bounds check is inlined here. The reallocation behind it runs
        once per doubling, but leaving it in this body made the whole thing
        `@no_inline`, so every insert paid for a call just to learn the mask
        was already big enough -- about 19% of the cost of an insert.

        Args:
            index: The entry index that must have a bit in the mask.
        """
        comptime if Self.destructive:
            if index >> 3 >= self.deleted_bytes:
                self._grow_deleted_mask(index)

    @no_inline
    def _grow_deleted_mask(mut self, index: Int):
        """Doubles the tombstone mask until it covers entry `index`.

        Args:
            index: The entry index that must have a bit in the mask.
        """
        var needed = (index >> 3) + 1
        var bytes = self.deleted_bytes
        while bytes < needed:
            bytes += bytes if bytes > 0 else 1
        # The keys container already holds end offsets for this many entries,
        # so sizing the mask to match makes the two grow at the same moments.
        # Left to double on its own from one byte, the mask reallocated four
        # times while building a map of 200 keys.
        var paired = (self._keys.capacity + 7) >> 3
        if paired > bytes:
            bytes = paired
        var grown = alloc[UInt8]({count = bytes}).unsafe_leak()
        unsafe_memset_zero(grown, bytes)
        unsafe_memcpy(
            dest=grown, src=self.deleted_mask, count=self.deleted_bytes
        )
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.deleted_mask,
                layout={count = self.deleted_bytes},
            )
        )
        self.deleted_mask = grown
        self.deleted_bytes = bytes

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

    @no_inline
    def _rehash(mut self):
        """Doubles the table, dropping deleted slots on the way.

        Tombstones are not carried over, which is what stops a map that churns
        from growing without bound. Hashes are recomputed rather than reused:
        the control byte keeps only seven bits and the cached hash is narrowed
        to `KeyCountType`, so neither can reconstruct the tag for the new table.
        """
        var old_capacity = self.capacity
        var old_control = self.control
        var old_slot_to_index = self.slot_to_index
        var old_key_hashes = self.key_hashes

        self.capacity <<= 1
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = self.capacity}
        ).unsafe_leak()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        self.control = alloc[UInt8](
            {count = self.capacity + GROUP}
        ).unsafe_leak()
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)

        comptime if Self.caching_hashes:
            self.key_hashes = alloc[Scalar[Self.KeyCountType]](
                {count = self.capacity}
            ).unsafe_leak()

        self.occupied = 0
        var mask = self.capacity - 1
        for i in range(old_capacity):
            if (old_control[unsafe_offset=i] & 0x80) != 0:
                continue  # empty or deleted
            var key_index = Int(old_slot_to_index[unsafe_offset=i])
            var key_hash = hash(self._keys[key_index - 1])
            var slot = Int(key_hash & UInt64(mask))
            while True:
                var group = self.control.unsafe_offset(slot).unsafe_load[
                    width=GROUP
                ]()
                var lane = Self._first_lane(
                    group.eq(SIMD[DType.uint8, GROUP](_EMPTY))
                )
                if lane != GROUP:
                    self._occupy((slot + lane) & mask, key_hash, key_index)
                    self.occupied += 1
                    break
                slot = (slot + GROUP) & mask

        dealloc(
            Allocation(
                unsafe_owned_ptr=old_control,
                layout={count = old_capacity + GROUP},
            )
        )
        dealloc(
            Allocation(
                unsafe_owned_ptr=old_slot_to_index,
                layout={count = old_capacity},
            )
        )
        comptime if Self.caching_hashes:
            dealloc(
                Allocation(
                    unsafe_owned_ptr=old_key_hashes,
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
        return self._values[key_index - 1].copy()

    def delete(mut self, key: StringSlice):
        """Removes `key`, if `destructive` is on and the key is present.

        The entry is tombstoned rather than removed: its slot and its key bytes
        stay, and re-inserting the same key revives it.

        Args:
            key: The key to remove.
        """
        comptime if not Self.destructive:
            return

        var slot = self._find_slot(key)
        if slot == -1:
            return
        self._remove_at(slot)

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
            self._values[key_index - 1] = update(
                self._values[key_index - 1].copy()
            )

    def clear(mut self):
        """Removes every entry, keeping the allocated storage."""
        self._values.clear()
        self._keys.clear()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)
        self.occupied = 0

        comptime if Self.destructive:
            unsafe_memset_zero(self.deleted_mask, self.deleted_bytes)
        self.count = 0

    @always_inline
    def _find_slot(self, key: StringSlice) -> Int:
        """Returns the slot holding `key`, or -1.

        A deleted slot never matches a tag, so a deleted key is simply not
        found -- the tombstone bit is not consulted here at all.
        """
        var key_hash = hash(key)
        var mask = self.capacity - 1
        var tag = SIMD[DType.uint8, GROUP](Self._tag(key_hash))
        var slot = Int(key_hash & UInt64(mask))
        while True:
            var group = self.control.unsafe_offset(slot).unsafe_load[
                width=GROUP
            ]()
            var matches = group.eq(tag)
            if matches.reduce_or():
                while True:
                    var lane = Self._first_lane(matches)
                    if lane == GROUP:
                        break
                    var candidate = (slot + lane) & mask
                    var key_index = Int(
                        self.slot_to_index.unsafe_load(candidate)
                    )
                    if self._matches(candidate, key_index, key, key_hash):
                        return candidate
                    matches[lane] = False
            if group.eq(SIMD[DType.uint8, GROUP](_EMPTY)).reduce_or():
                return -1
            slot = (slot + GROUP) & mask

    @always_inline
    def _find_key_index(self, key: StringSlice) -> Int:
        """Returns the one-based index of `key`'s entry, or 0 if absent.

        Args:
            key: The key to look for.

        Returns:
            The entry's index plus one, or zero.
        """
        var slot = self._find_slot(key)
        if slot == -1:
            return 0
        return Int(self.slot_to_index.unsafe_load(slot))


# ===-----------------------------------------------------------------------===#
# Iterators
# ===-----------------------------------------------------------------------===#


comptime _DictOf[
    V: Copyable & Deinitable,
    KeyCountType: DType,
    KeyOffsetType: DType,
    destructive: Bool,
    caching_hashes: Bool,
] = StringDict[V, KeyCountType, KeyOffsetType, destructive, caching_hashes]
"""Spelling out the map's five parameters once, for the iterators."""


@fieldwise_init
struct Entry[V: Copyable & Deinitable, origin: ImmOrigin](Copyable, Movable):
    """One live entry, as yielded by `StringDict.items()`.

    Parameters:
        V: The value type.
        origin: The origin of the map the key borrows from.
    """

    var key: StringSlice[Self.origin]
    """The entry's key, borrowing the map's key buffer."""
    var value: Self.V
    """A copy of the entry's value."""


struct _KeysIter[
    mut: Bool,
    //,
    V: Copyable & Deinitable,
    KeyCountType: DType,
    KeyOffsetType: DType,
    destructive: Bool,
    caching_hashes: Bool,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields the live keys of a `StringDict`, in insertion order.

    Parameters:
        mut: Whether the borrow of the map is mutable.
        V: The value type.
        KeyCountType: The map's key count type.
        KeyOffsetType: The map's key offset type.
        destructive: Whether the map supports deletion.
        caching_hashes: Whether the map caches hashes.
        origin: The origin of the borrowed map.
    """

    comptime Element = StringSlice[ImmOrigin(Self.origin)]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[
        _DictOf[
            Self.V,
            Self.KeyCountType,
            Self.KeyOffsetType,
            Self.destructive,
            Self.caching_hashes,
        ],
        Self.origin,
    ]
    var _index: Int

    def __init__(
        out self,
        src: Pointer[
            _DictOf[
                Self.V,
                Self.KeyCountType,
                Self.KeyOffsetType,
                Self.destructive,
                Self.caching_hashes,
            ],
            Self.origin,
        ],
    ):
        """Starts at the first live entry.

        Args:
            src: The map to walk.
        """
        self._src = src
        self._index = src[]._next_live(0)

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        """Returns the next live key.

        Raises:
            StopIteration: When every entry has been yielded.

        Returns:
            The key, borrowing the map's key buffer.
        """
        if self._index == -1:
            raise StopIteration()
        var index = self._index
        self._index = self._src[]._next_live(index + 1)
        # The container hands back a slice carrying an origin interior to the
        # map; rebuild it against the whole-map origin the iterator promises.
        var borrowed = self._src[]._keys[index]
        return StringSlice[ImmOrigin(Self.origin)](
            unsafe_from_utf8=Span[Byte, ImmOrigin(Self.origin)](
                unsafe_ptr=borrowed.unsafe_ptr().unsafe_origin_cast[
                    ImmOrigin(Self.origin)
                ](),
                length=borrowed.byte_length(),
            )
        )


struct _ValuesIter[
    mut: Bool,
    //,
    V: Copyable & Deinitable,
    KeyCountType: DType,
    KeyOffsetType: DType,
    destructive: Bool,
    caching_hashes: Bool,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields references to the live values of a `StringDict`.

    Parameters:
        mut: Whether the borrow of the map is mutable.
        V: The value type.
        KeyCountType: The map's key count type.
        KeyOffsetType: The map's key offset type.
        destructive: Whether the map supports deletion.
        caching_hashes: Whether the map caches hashes.
        origin: The origin of the borrowed map.
    """

    comptime Element = Self.V
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[
        _DictOf[
            Self.V,
            Self.KeyCountType,
            Self.KeyOffsetType,
            Self.destructive,
            Self.caching_hashes,
        ],
        Self.origin,
    ]
    var _index: Int

    def __init__(
        out self,
        src: Pointer[
            _DictOf[
                Self.V,
                Self.KeyCountType,
                Self.KeyOffsetType,
                Self.destructive,
                Self.caching_hashes,
            ],
            Self.origin,
        ],
    ):
        """Starts at the first live entry.

        Args:
            src: The map to walk.
        """
        self._src = src
        self._index = src[]._next_live(0)

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(
        mut self,
    ) raises StopIteration -> ref[Self.origin] Self.Element:
        """Returns a reference to the next live value.

        Raises:
            StopIteration: When every entry has been yielded.

        Returns:
            A reference to the value, borrowing the map.
        """
        if self._index == -1:
            raise StopIteration()
        var index = self._index
        self._index = self._src[]._next_live(index + 1)
        # `List.__getitem__` vends an interior origin, which cannot widen to
        # the whole-map origin an iterator's references need.
        return (
            self._src[]
            ._values.unsafe_ptr()
            .unsafe_origin_cast[Self.origin]()[unsafe_offset=index]
        )


struct _ItemsIter[
    mut: Bool,
    //,
    V: Copyable & Deinitable,
    KeyCountType: DType,
    KeyOffsetType: DType,
    destructive: Bool,
    caching_hashes: Bool,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields the live entries of a `StringDict`, in insertion order.

    Parameters:
        mut: Whether the borrow of the map is mutable.
        V: The value type.
        KeyCountType: The map's key count type.
        KeyOffsetType: The map's key offset type.
        destructive: Whether the map supports deletion.
        caching_hashes: Whether the map caches hashes.
        origin: The origin of the borrowed map.
    """

    comptime Element = Entry[Self.V, ImmOrigin(Self.origin)]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[
        _DictOf[
            Self.V,
            Self.KeyCountType,
            Self.KeyOffsetType,
            Self.destructive,
            Self.caching_hashes,
        ],
        Self.origin,
    ]
    var _index: Int

    def __init__(
        out self,
        src: Pointer[
            _DictOf[
                Self.V,
                Self.KeyCountType,
                Self.KeyOffsetType,
                Self.destructive,
                Self.caching_hashes,
            ],
            Self.origin,
        ],
    ):
        """Starts at the first live entry.

        Args:
            src: The map to walk.
        """
        self._src = src
        self._index = src[]._next_live(0)

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        """Returns the next live entry.

        Raises:
            StopIteration: When every entry has been yielded.

        Returns:
            The entry, with a borrowed key and a copied value.
        """
        if self._index == -1:
            raise StopIteration()
        var index = self._index
        self._index = self._src[]._next_live(index + 1)
        var borrowed = self._src[]._keys[index]
        var key = StringSlice[ImmOrigin(Self.origin)](
            unsafe_from_utf8=Span[Byte, ImmOrigin(Self.origin)](
                unsafe_ptr=borrowed.unsafe_ptr().unsafe_origin_cast[
                    ImmOrigin(Self.origin)
                ](),
                length=borrowed.byte_length(),
            )
        )
        return Entry[Self.V, ImmOrigin(Self.origin)](
            key, self._src[]._values[index].copy()
        )
