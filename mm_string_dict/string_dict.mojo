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
from std.os import abort
from std.memory import (
    unsafe_destroy_n,
    unsafe_uninit_copy_n,
    unsafe_uninit_move_n,
)
from std.memory.alloc import Allocation, alloc, dealloc
from std.sys.info import align_of, simd_width_of, size_of


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


@always_inline
def _entry_block[
    V: AnyType, caching_hashes: Bool, destructive: Bool
](capacity: Int) -> Tuple[Int, Int, Int]:
    """Byte offsets of the value and mask regions, and the block's total size.

    The three entry-indexed regions share one allocation. Hashes go first, at
    offset zero, so their 8-byte alignment comes free from the block's own;
    their region is a whole number of 8-byte words, so the values that follow
    land on an offset the allocator's alignment already satisfies.

    Parameters:
        V: The value type.
        caching_hashes: Whether a hash region is present.
        destructive: Whether a tombstone mask is present.

    Args:
        capacity: The number of entries the block must hold.

    Returns:
        The value offset, the mask offset, and the total size in bytes.
    """
    var values = 0
    comptime if caching_hashes:
        values = capacity * size_of[UInt64]()
    var mask = values + capacity * size_of[V]()
    var total = mask
    comptime if destructive:
        total += (capacity + 7) >> 3
    # An allocation of nothing is still a pointer that must be free-able.
    return (values, mask, total if total > 0 else 1)


@always_inline
def _slot_block_count[KeyCountType: DType](capacity: Int) -> Int:
    """Elements of `KeyCountType` holding both slot regions at once.

    `slot_to_index` and `control` are both exactly `capacity` long and are
    always reallocated together -- the only two regions in the map that share a
    growth schedule -- so they share an allocation. Indices come first, being
    the more strictly aligned of the two.

    Parameters:
        KeyCountType: The element type of the index region.

    Args:
        capacity: The slot capacity the block must cover.

    Returns:
        The number of `KeyCountType` elements to allocate.
    """
    comptime INDEX = size_of[Scalar[KeyCountType]]()
    return capacity + (capacity + GROUP + INDEX - 1) // INDEX


# `put` checks the entry cap only for index types narrower than this. At 32
# bits the cap is four billion entries, which no map that fits in memory can
# reach, so wider types pay nothing for the check. Narrower ones are opt-in and
# genuinely reachable.
comptime _CHECKED_INDEX_BITS = 32
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
            caps the number of entries at its maximum value -- `uint8` 255,
            `uint16` 65535, the default `uint32` four billion -- and a narrower
            one shrinks the slot array to match. The cap counts every entry
            ever inserted, including deleted ones, which are never renumbered;
            a map that churns reaches it sooner than its live count suggests.
            Exceeding it is a programming error, and `put` asserts on it in
            builds with assertions enabled.
        KeyOffsetType: The unsigned integer type holding key end offsets, which
            caps the total size of all keys together.
        destructive: Whether `delete` is supported. It costs one bit per entry
            for the tombstone mask; with it off, `delete` does nothing.
        caching_hashes: Whether to keep each key's full 64-bit hash, indexed
            by entry. Growing the table then reuses the stored hash instead of
            hashing every key again, which is where the cost of growth sits:
            it takes growth from 12.3ns per insert to 10.9 and halves the gap
            to the stdlib `Dict`, worth 4-7% on a corpus build. It does *not*
            measurably change lookups, long keys included -- a lookup that
            finds its key compares the key bytes anyway, and the control byte
            already rejects 127 of every 128 wrong slots before that. The
            price is 8 bytes per entry, which measured 19-34% of a whole map
            on the corpora. Off by default, because footprint is what this
            container is for; turn it on for insert-heavy maps that grow.
    """

    var _keys: KeysContainer[Self.KeyOffsetType]
    """The keys, packed end to end. Reachable through `key_storage()`."""
    var control: Pointer[UInt8, MutUntrackedOrigin]
    """One byte per slot: `_EMPTY`, `_DELETED`, or the top seven bits of the
    key's hash. `GROUP` of them are compared at once, and the first `GROUP`
    bytes are mirrored past the end so a load near the end stays in bounds."""
    var entries: Pointer[UInt8, MutUntrackedOrigin]
    """One allocation holding every entry-indexed region: the cached hashes,
    the values, and the tombstone mask. They are indexed by entry rather than
    by slot, and so grow together, on a schedule of their own -- reusing a
    deleted slot still appends an entry, so under churn entries outnumber
    slots."""
    var entry_capacity: Int
    """Entries the block has room for, shared by all three regions."""
    var entry_hashes: Pointer[UInt64, MutUntrackedOrigin]
    """Each key's full hash, indexed by entry rather than by slot, when
    `caching_hashes` is on. Keyed by entry it survives a rehash, which is what
    lets the rehash reuse it; keyed by slot it would not."""
    var _values: Pointer[Self.V, MutUntrackedOrigin]
    """The values, in insertion order, parallel to the keys."""
    var slot_to_index: Pointer[Scalar[Self.KeyCountType], MutUntrackedOrigin]
    """One-based key index per slot; zero means the slot is empty."""
    var deleted_mask: Pointer[UInt8, MutUntrackedOrigin]
    """One bit per entry marking it deleted, when `destructive` is on."""
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

        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = _slot_block_count[Self.KeyCountType](self.capacity)}
        ).unsafe_leak()
        self.control = self.slot_to_index.unsafe_offset(
            self.capacity
        ).unsafe_bitcast[UInt8]()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)
        self.entry_capacity = self._keys.capacity
        self.entries = Self._alloc_entries(self.entry_capacity)
        # Placeholders; `_bind_entries` sets all three from `entries`.
        self.entry_hashes = self.entries.unsafe_bitcast[UInt64]()
        self._values = self.entries.unsafe_bitcast[Self.V]()
        self.deleted_mask = self.entries
        self._bind_entries()
        self._clear_mask(0)

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy.

        Args:
            copy: The map to duplicate.
        """
        self.count = copy.count
        self.occupied = copy.occupied
        self.capacity = copy.capacity
        self._keys = copy._keys

        # One block holds both regions, so one memcpy duplicates them.
        var block = _slot_block_count[Self.KeyCountType](self.capacity)
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = block}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self.slot_to_index, src=copy.slot_to_index, count=block
        )
        self.control = self.slot_to_index.unsafe_offset(
            self.capacity
        ).unsafe_bitcast[UInt8]()
        self.entry_capacity = copy.entry_capacity
        self.entries = Self._alloc_entries(self.entry_capacity)
        self.entry_hashes = self.entries.unsafe_bitcast[UInt64]()
        self._values = self.entries.unsafe_bitcast[Self.V]()
        self.deleted_mask = self.entries
        self._bind_entries()
        # The hashes and the mask are plain bytes, but the values are `V` and
        # may own memory, so they are copied one by one rather than memcpy'd.
        unsafe_uninit_copy_n[overlapping=False](
            dest=self._values, src=copy._values, count=copy._keys.count
        )
        comptime if Self.caching_hashes:
            unsafe_memcpy(
                dest=self.entry_hashes,
                src=copy.entry_hashes,
                count=copy._keys.count,
            )
        comptime if Self.destructive:
            unsafe_memcpy(
                dest=self.deleted_mask,
                src=copy.deleted_mask,
                count=(self.entry_capacity + 7) >> 3,
            )

    def __init__(out self, *, deinit move: Self):
        """Takes over `move`'s storage.

        Args:
            move: The map to move from.
        """
        self._keys = move._keys^
        self.control = move.control
        self.entries = move.entries
        self.entry_capacity = move.entry_capacity
        self.entry_hashes = move.entry_hashes
        self._values = move._values
        self.slot_to_index = move.slot_to_index
        self.deleted_mask = move.deleted_mask
        self.count = move.count
        self.occupied = move.occupied
        self.capacity = move.capacity

    @staticmethod
    @always_inline
    def _entry_words(capacity: Int) -> Int:
        """The entry block's size for `capacity` entries, in 8-byte words.

        The block is allocated as `UInt64` rather than as bytes, which is what
        gives the hash region its 8-byte alignment; the values that follow sit
        at a multiple of 8 and so are aligned for any `V` the constraint below
        admits.

        Args:
            capacity: The number of entries the block must hold.

        Returns:
            The number of `UInt64` words to allocate.
        """
        comptime assert align_of[Self.V]() <= align_of[UInt64](), (
            "StringDict values must not need more than 8-byte alignment; the"
            " entry block is a word array"
        )
        var block = _entry_block[Self.V, Self.caching_hashes, Self.destructive](
            capacity
        )
        return (block[2] + 7) >> 3

    @staticmethod
    @always_inline
    def _alloc_entries(capacity: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Allocates one block for every entry-indexed region.

        Args:
            capacity: The number of entries the block must hold.

        Returns:
            The block's base pointer.
        """
        return (
            alloc[UInt64]({count = Self._entry_words(capacity)})
            .unsafe_leak()
            .unsafe_bitcast[UInt8]()
        )

    @always_inline
    def _bind_entries(mut self):
        """Points the three region fields into `entries`.

        Called after every allocation of the block. The regions are kept as
        fields rather than recomputed per access, for the same reason the probe
        loop hoists its pointers: they all derive from one allocation, so the
        compiler cannot prove a store through one misses a load through
        another, and would reload the offsets on every use.
        """
        var block = _entry_block[Self.V, Self.caching_hashes, Self.destructive](
            self.entry_capacity
        )
        self.entry_hashes = self.entries.unsafe_bitcast[UInt64]()
        self._values = self.entries.unsafe_offset(block[0]).unsafe_bitcast[
            Self.V
        ]()
        self.deleted_mask = self.entries.unsafe_offset(block[1])

    @always_inline
    def _clear_mask(mut self, first: Int):
        """Zeroes the tombstone bits for entries from `first` on.

        Args:
            first: The first entry index whose bit must be cleared.
        """
        comptime if Self.destructive:
            var from_byte = first >> 3
            var to_byte = (self.entry_capacity + 7) >> 3
            if to_byte > from_byte:
                unsafe_memset_zero(
                    self.deleted_mask.unsafe_offset(from_byte),
                    to_byte - from_byte,
                )

    def __deinit__(deinit self):
        """Releases the slot array and the optional side tables."""
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.slot_to_index,
                layout={
                    count = _slot_block_count[Self.KeyCountType](self.capacity)
                },
            )
        )
        # Every entry ever added still owns its value, deleted ones included:
        # entries are never renumbered, so a deleted entry's value lives until
        # the map does.
        unsafe_destroy_n(self._values, self._keys.count)
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.entries.unsafe_bitcast[UInt64](),
                layout={count = Self._entry_words(self.entry_capacity)},
            )
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
            return self._values[unsafe_offset=key_index - 1].copy()
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
            return self._values[unsafe_offset=key_index - 1].copy()
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
            var value = self._values[unsafe_offset=key_index - 1].copy()
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
            var value = self._values[unsafe_offset=key_index - 1].copy()
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
            self.put(other._keys[index], other._values[unsafe_offset=index])

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
        # Both regions live in one allocation now, so the compiler can no
        # longer tell a store through one from a load through the other and
        # would reload the fields on every pass. Loading each once, up front,
        # is what keeps the probe loop reading from registers.
        var control = self.control
        var slot_to_index = self.slot_to_index

        while True:
            var group = control.unsafe_offset(slot).unsafe_load[width=GROUP]()

            # Does one of these slots already hold this key? Most groups hold
            # no candidate at all, and one reduce answers that.
            var matches = group.eq(tag)
            if matches.reduce_or():
                while True:
                    var lane = Self._first_lane(matches)
                    if lane == GROUP:
                        break
                    var candidate = (slot + lane) & mask
                    var key_index = Int(slot_to_index.unsafe_load(candidate))
                    if self._matches(candidate, key_index, key, key_hash):
                        self._values[unsafe_offset=key_index - 1] = value.copy()
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

        # `slot_to_index` holds a one-based entry index in a
        # `Scalar[KeyCountType]`, so entry number `MAX` is the last one that
        # can be addressed. Past it the index wraps and the map silently hands
        # back other keys' values. Entries include deleted ones, which are
        # never renumbered, so a churning map reaches this sooner than its live
        # count suggests.
        comptime INDEX_BITS = size_of[Scalar[Self.KeyCountType]]() * 8
        comptime if INDEX_BITS < _CHECKED_INDEX_BITS:
            # Computed from the width rather than from `Scalar.MAX`, which
            # wraps to -1 for `uint64` once it is cast to a signed `Int`.
            comptime MAX_ENTRIES = (1 << INDEX_BITS) - 1
            # Always checked, not `debug_assert`: the failure is a wrong answer
            # rather than a crash, and it is silent at the assertion levels a
            # release build uses.
            if self._keys.count >= MAX_ENTRIES:
                abort(
                    String(
                        "StringDict: ",
                        MAX_ENTRIES,
                        (
                            " entries is all this KeyCountType can index, and"
                            " this is entry "
                        ),
                        self._keys.count + 1,
                        (
                            ". Widen KeyCountType. Deleted entries count, since"
                            " they are never renumbered."
                        ),
                    )
                )
        self._keys.add(key)
        var index = self._keys.count - 1
        self._reserve_entry(index)
        self._values.unsafe_offset(index).unsafe_write(value.copy())
        comptime if Self.caching_hashes:
            self.entry_hashes.unsafe_store(index, key_hash)
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
            if self.entry_hashes[unsafe_offset=key_index - 1] != key_hash:
                return False
        return self._keys[key_index - 1] == key

    @always_inline
    def _occupy(mut self, slot: Int, key_hash: UInt64, key_index: Int):
        """Writes an entry into a slot, control byte and mirror included."""
        self.slot_to_index.unsafe_store(
            slot, Scalar[Self.KeyCountType](key_index)
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
    def _reserve_entry(mut self, index: Int):
        """Makes sure every entry region has room for entry `index`.

        One bounds check now covers the hashes, the values and the tombstone
        mask, where each used to check and grow separately. Only the check is
        inlined; the reallocation behind it runs once per doubling, and leaving
        it in this body made the whole thing `@no_inline`, so every insert paid
        for a call just to learn there was room -- about 19% of an insert.

        Args:
            index: The entry index that must fit.
        """
        if index >= self.entry_capacity:
            self._grow_entries(index)

    @no_inline
    def _grow_entries(mut self, index: Int):
        """Moves every entry region into a larger block.

        Args:
            index: The entry index that must fit.
        """
        var old_capacity = self.entry_capacity
        var old_entries = self.entries
        var old_values = self._values
        var old_hashes = self.entry_hashes
        var old_mask = self.deleted_mask

        var grown = old_capacity
        while grown <= index:
            grown += grown if grown > 0 else 1
        # The keys container holds end offsets for this many entries already;
        # matching it keeps the two from reallocating on separate schedules.
        if self._keys.capacity > grown:
            grown = self._keys.capacity

        self.entry_capacity = grown
        self.entries = Self._alloc_entries(grown)
        self._bind_entries()

        # Values may own memory, so they are moved rather than copied; the
        # hashes and the mask are plain bytes.
        unsafe_uninit_move_n[overlapping=False](
            dest=self._values, src=old_values, count=self._keys.count
        )
        comptime if Self.caching_hashes:
            unsafe_memcpy(
                dest=self.entry_hashes,
                src=old_hashes,
                count=self._keys.count,
            )
        comptime if Self.destructive:
            var carried = (old_capacity + 7) >> 3
            unsafe_memcpy(dest=self.deleted_mask, src=old_mask, count=carried)
            self._clear_mask(carried << 3)

        dealloc(
            Allocation(
                unsafe_owned_ptr=old_entries.unsafe_bitcast[UInt64](),
                layout={count = Self._entry_words(old_capacity)},
            )
        )

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
        from growing without bound.

        With `caching_hashes` off, every key is hashed again here: the control
        byte keeps only seven bits, and the slot a key sat in reveals only the
        low bits of its hash, so neither can reconstruct a tag for the doubled
        table. With it on, the stored hash is reused and this loop does no
        hashing at all.
        """
        var old_capacity = self.capacity
        var old_control = self.control
        var old_slot_to_index = self.slot_to_index

        self.capacity <<= 1
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = _slot_block_count[Self.KeyCountType](self.capacity)}
        ).unsafe_leak()
        self.control = self.slot_to_index.unsafe_offset(
            self.capacity
        ).unsafe_bitcast[UInt8]()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)

        self.occupied = 0
        var mask = self.capacity - 1
        for i in range(old_capacity):
            if (old_control[unsafe_offset=i] & 0x80) != 0:
                continue  # empty or deleted
            var key_index = Int(old_slot_to_index[unsafe_offset=i])
            # The whole point of caching by entry: a rehash moves every live
            # entry, and hashing each key again is the single largest part of
            # what growth costs.
            var key_hash: UInt64
            comptime if Self.caching_hashes:
                key_hash = self.entry_hashes[unsafe_offset=key_index - 1]
            else:
                key_hash = hash(self._keys[key_index - 1])
            var slot = Int(key_hash & UInt64(mask))
            var control = self.control
            while True:
                var group = control.unsafe_offset(slot).unsafe_load[
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
                unsafe_owned_ptr=old_slot_to_index,
                layout={
                    count = _slot_block_count[Self.KeyCountType](old_capacity)
                },
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
        return self._values[unsafe_offset=key_index - 1].copy()

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
            self._values[unsafe_offset=key_index - 1] = update(
                self._values[unsafe_offset=key_index - 1].copy()
            )

    def clear(mut self):
        """Removes every entry, keeping the allocated storage."""
        unsafe_destroy_n(self._values, self._keys.count)
        self._keys.clear()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)
        self.occupied = 0
        self._clear_mask(0)
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
        # Both regions live in one allocation now, so the compiler can no
        # longer tell a store through one from a load through the other and
        # would reload the fields on every pass. Loading each once, up front,
        # is what keeps the probe loop reading from registers.
        var control = self.control
        var slot_to_index = self.slot_to_index
        while True:
            var group = control.unsafe_offset(slot).unsafe_load[width=GROUP]()
            var matches = group.eq(tag)
            if matches.reduce_or():
                while True:
                    var lane = Self._first_lane(matches)
                    if lane == GROUP:
                        break
                    var candidate = (slot + lane) & mask
                    var key_index = Int(slot_to_index.unsafe_load(candidate))
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
        # The value region is held as a raw pointer with an untracked origin,
        # so its mutability is fixed while `Self.origin`'s is a parameter.
        # Re-origin it through a `Span`, which carries the origin the iterator
        # promises and hands back references in it.
        return Span[Self.V, Self.origin](
            unsafe_ptr=self._src[]
            ._values.unsafe_mut_cast[Self.origin.mut]()
            .unsafe_origin_cast[Self.origin](),
            length=index + 1,
        )[index]


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
            key, self._src[]._values[unsafe_offset=index].copy()
        )
