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
    V: AnyType,
    KeyEndType: DType,
    HashCacheType: DType,
    caching_hashes: Bool,
    destructive: Bool,
](capacity: Int) -> Tuple[Int, Int, Int, Int]:
    """Byte offsets of each entry region, and the block's total size.

    Every region here is indexed by entry, and there is exactly one entry per
    key, so one capacity serves all four and they grow in a single step. The
    packed key bytes are the exception and live in their own buffer: they grow
    when the bytes run out, which has nothing to do with the entry count.

    Regions are laid out most-aligned first, and each start is rounded up to
    what the region needs. The cached hashes keep only the low 32 bits of a
    hash, which is all a rehash requires: the new slot is `hash & new_mask`,
    and no table reaches 2^32 slots.

    Parameters:
        V: The value type.
        KeyEndType: The type of a key end offset.
        HashCacheType: The type of a cached hash.
        caching_hashes: Whether a hash region is present.
        destructive: Whether a tombstone mask is present.

    Args:
        capacity: The number of entries the block must hold.

    Returns:
        The offsets of the end-offset, value and mask regions, and the total
        size in bytes.
    """
    var ends = 0
    comptime if caching_hashes:
        ends = capacity * size_of[Scalar[HashCacheType]]()
    comptime EALIGN = align_of[Scalar[KeyEndType]]()
    ends = ((ends + EALIGN - 1) // EALIGN) * EALIGN
    var values = ends + capacity * size_of[Scalar[KeyEndType]]()
    comptime VALIGN = align_of[V]()
    values = ((values + VALIGN - 1) // VALIGN) * VALIGN
    var mask = values + capacity * size_of[V]()
    var total = mask
    comptime if destructive:
        total += (capacity + 7) >> 3
    # An allocation of nothing is still a pointer that must be free-able.
    return (ends, values, mask, total if total > 0 else 1)


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
"""The smallest number of entries a map will allocate room for."""


struct StringDict[
    V: Copyable & Deinitable,
    KeyCountType: DType = .uint32,
    KeyOffsetType: DType = .uint32,
    destructive: Bool = True,
    caching_hashes: Bool = True,
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
        caching_hashes: Whether to keep the low 32 bits of each key's hash,
            indexed by entry. On by default, and worth it for two reasons.

            Growing the table reuses the stored bits instead of hashing every
            key again, which is where the cost of growth sits: growth drops
            from 11.4ns per insert to 8.9, under the stdlib `Dict`'s 9.4, and
            an insert into a map growing from empty goes from 22.8ns to 19.0
            against the stdlib's 20.1. Thirty-two bits are all a rehash needs
            -- the new slot is `hash & new_mask`, and the new tag is copied
            from the control byte the entry already had.

            A lookup also compares those bits before the key bytes, past the
            control byte's seven. That does not measurably change lookups, so
            it is not the reason to keep this on.

            The price is 4 bytes per entry, about 12% of a map. Turn it off
            for the smallest possible footprint, at a build roughly 1.3x the
            stdlib's instead of 1.15x.
    """

    comptime _HashCacheType = (
        DType.uint16 if (
            Self.KeyCountType == .uint8 or Self.KeyCountType == .uint16
        ) else DType.uint32
    )
    """How much of a hash to cache, derived from how many entries can exist.

    A rehash uses the cached bits as `hash & new_mask`, so it needs as many
    bits as the new capacity has. A `uint16` entry index caps the map at 65535
    entries, and a table for those never needs more than 17 bits of mask -- so
    16 bits cover every capacity up to 65536, and `_rehash` falls back to
    hashing for the single doubling past that. Halving this array is worth 2
    bytes an entry on top of the 2 the narrower slot index already saves."""

    var _key_buffer: Pointer[UInt8, MutUntrackedOrigin]
    """Every key's bytes, one after another with no separator and no per-key
    header. This is the one buffer that does not grow with the entry count: it
    grows when the bytes run out, which depends on how long the keys are."""
    var allocated_bytes: Int
    """How many bytes `_key_buffer` can hold."""
    var entry_count: Int
    """Entries ever added, deleted ones included. They are never renumbered."""
    var keys_end: Pointer[Scalar[Self.KeyOffsetType], MutUntrackedOrigin]
    """Where each key ends in `_key_buffer`; key `i` runs from `keys_end[i-1]`
    to `keys_end[i]`. One offset per key instead of a `String` header and an
    allocation each."""
    var control: Pointer[UInt8, MutUntrackedOrigin]
    """One byte per slot: `_EMPTY`, `_DELETED`, or the top seven bits of the
    key's hash. `GROUP` of them are compared at once, and the first `GROUP`
    bytes are mirrored past the end so a load near the end stays in bounds."""
    var entries: Pointer[UInt8, MutUntrackedOrigin]
    """One allocation holding every entry-indexed region: the cached hashes,
    the key end offsets, the values, and the tombstone mask. All four are
    indexed by entry and there is exactly one entry per key, so they share a
    capacity and grow in one step. Entries are indexed separately from slots --
    reusing a deleted slot still appends an entry, so under churn entries
    outnumber slots."""
    var entry_capacity: Int
    """Entries the block has room for, shared by all three regions."""
    var entry_hashes: Pointer[Scalar[Self._HashCacheType], MutUntrackedOrigin]
    """The low 32 bits of each key's hash, indexed by entry rather than by
    slot, when `caching_hashes` is on.

    Keyed by entry it survives a rehash, which is what lets the rehash reuse
    it; keyed by slot it would not. Thirty-two bits are enough: a rehash needs
    the new slot, which is `hash & new_mask`, and the new tag, which it copies
    from the old control byte rather than recomputing from the top of the
    hash."""
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
        self.slot_to_index = alloc[Scalar[Self.KeyCountType]](
            {count = _slot_block_count[Self.KeyCountType](self.capacity)}
        ).unsafe_leak()
        self.control = self.slot_to_index.unsafe_offset(
            self.capacity
        ).unsafe_bitcast[UInt8]()
        unsafe_memset_zero(self.slot_to_index, self.capacity)
        unsafe_memset(self.control, _EMPTY, self.capacity + GROUP)
        self.entry_count = 0
        self.entry_capacity = (
            self.capacity if self.capacity > _MIN_KEYS else _MIN_KEYS
        )
        self.entries = Self._alloc_entries(self.entry_capacity)
        # Placeholders; `_bind_entries` sets all four from `entries`.
        self.entry_hashes = self.entries.unsafe_bitcast[
            Scalar[Self._HashCacheType]
        ]()
        self.keys_end = self.entries.unsafe_bitcast[
            Scalar[Self.KeyOffsetType]
        ]()
        self._values = self.entries.unsafe_bitcast[Self.V]()
        self.deleted_mask = self.entries
        # Eight bytes a key is a guess at the average, and the buffer grows
        # from there; it is the only region whose size the entry count does not
        # decide.
        self.allocated_bytes = self.entry_capacity << 3
        self._key_buffer = alloc[UInt8](
            {count = self.allocated_bytes}
        ).unsafe_leak()
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
        self.entry_count = copy.entry_count

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
        self.entry_hashes = self.entries.unsafe_bitcast[
            Scalar[Self._HashCacheType]
        ]()
        self.keys_end = self.entries.unsafe_bitcast[
            Scalar[Self.KeyOffsetType]
        ]()
        self._values = self.entries.unsafe_bitcast[Self.V]()
        self.deleted_mask = self.entries
        self.allocated_bytes = copy.allocated_bytes
        self._key_buffer = alloc[UInt8](
            {count = self.allocated_bytes}
        ).unsafe_leak()
        unsafe_memcpy(
            dest=self._key_buffer,
            src=copy._key_buffer,
            count=copy.allocated_bytes,
        )
        self._bind_entries()
        unsafe_memcpy(
            dest=self.keys_end, src=copy.keys_end, count=copy.entry_count
        )
        # The offsets, hashes and mask are plain bytes, but the values are `V`
        # and may own memory, so they are copied one by one rather than
        # memcpy'd.
        unsafe_uninit_copy_n[overlapping=False](
            dest=self._values, src=copy._values, count=copy.entry_count
        )
        comptime if Self.caching_hashes:
            unsafe_memcpy(
                dest=self.entry_hashes,
                src=copy.entry_hashes,
                count=copy.entry_count,
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
        self._key_buffer = move._key_buffer
        self.allocated_bytes = move.allocated_bytes
        self.entry_count = move.entry_count
        self.keys_end = move.keys_end
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
        var block = _entry_block[
            Self.V,
            Self.KeyOffsetType,
            Self._HashCacheType,
            Self.caching_hashes,
            Self.destructive,
        ](capacity)
        return (block[3] + 7) >> 3

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
        """Points the four region fields into `entries`.

        Called after every allocation of the block. The regions are kept as
        fields rather than recomputed per access, for the same reason the probe
        loop hoists its pointers: they all derive from one allocation, so the
        compiler cannot prove a store through one misses a load through
        another, and would reload the offsets on every use.
        """
        var block = _entry_block[
            Self.V,
            Self.KeyOffsetType,
            Self._HashCacheType,
            Self.caching_hashes,
            Self.destructive,
        ](self.entry_capacity)
        self.entry_hashes = self.entries.unsafe_bitcast[
            Scalar[Self._HashCacheType]
        ]()
        self.keys_end = self.entries.unsafe_offset(block[0]).unsafe_bitcast[
            Scalar[Self.KeyOffsetType]
        ]()
        self._values = self.entries.unsafe_offset(block[1]).unsafe_bitcast[
            Self.V
        ]()
        self.deleted_mask = self.entries.unsafe_offset(block[2])

    @always_inline
    def _append_key(
        mut self,
        key: StringSlice,
        index: Int,
        ends: Pointer[Scalar[Self.KeyOffsetType], MutUntrackedOrigin],
    ):
        """Copies `key` into the packed buffer and records where it ends.

        The caller must have reserved entry `index` already, since the end
        offset it writes lives in the entry block.

        Args:
            key: The key to store. Its bytes are copied.
            index: The entry index this key belongs to.
            ends: The end-offset region, passed in so the caller's hoisted
                pointer is used instead of a reload of the field.
        """
        var prev_end = 0 if index == 0 else Int(ends[unsafe_offset=index - 1])
        var length = key.byte_length()
        var new_end = prev_end + length

        # Grown inline rather than behind a call: the same split measured 2-3%
        # slower here, the hot path being a handful of instructions around a
        # `memcpy`. See docs/improvements.md.
        if new_end > self.allocated_bytes:
            var old_bytes = self.allocated_bytes
            while self.allocated_bytes < new_end:
                self.allocated_bytes += (self.allocated_bytes >> 1) + 1
            var grown = alloc[UInt8](
                {count = self.allocated_bytes}
            ).unsafe_leak()
            unsafe_memcpy(dest=grown, src=self._key_buffer, count=prev_end)
            dealloc(
                Allocation(
                    unsafe_owned_ptr=self._key_buffer,
                    layout={count = old_bytes},
                )
            )
            self._key_buffer = grown

        unsafe_memcpy(
            dest=self._key_buffer.unsafe_offset(prev_end),
            src=Pointer(key.unsafe_ptr()),
            count=length,
        )
        ends.unsafe_store(index, Scalar[Self.KeyOffsetType](new_end))

    @always_inline
    def _key_at(self, index: Int) -> StringSlice[ImmOrigin(origin_of(self))]:
        """Returns the key of entry `index`, or an empty slice if out of range.

        Args:
            index: The entry index.

        Returns:
            A slice borrowing the map's key buffer.
        """
        var buffer = self._key_buffer.as_imm().unsafe_origin_cast[
            origin_of(self)
        ]()
        if index < 0 or index >= self.entry_count:
            return StringSlice(
                unsafe_from_utf8=Span(unsafe_ptr=buffer, length=0)
            )
        var start = 0 if index == 0 else Int(
            self.keys_end[unsafe_offset=index - 1]
        )
        var length = Int(self.keys_end[unsafe_offset=index]) - start
        return StringSlice(
            unsafe_from_utf8=Span(
                unsafe_ptr=buffer.unsafe_offset(start), length=length
            )
        )

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
        unsafe_destroy_n(self._values, self.entry_count)
        dealloc(
            Allocation(
                unsafe_owned_ptr=self.entries.unsafe_bitcast[
                    Scalar[Self._HashCacheType]
                ](),
                layout={count = Self._entry_words(self.entry_capacity)},
            )
        )
        dealloc(
            Allocation(
                unsafe_owned_ptr=self._key_buffer,
                layout={count = self.allocated_bytes},
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
        return self.allocated_bytes

    def print_keys(self):
        """Prints every stored key, live or deleted, for debugging."""
        print("(", self.entry_count, ")[", sep="", end="")
        for i in range(self.entry_count):
            print(self._key_at(i), end=", " if i < self.entry_count - 1 else "")
        print("]")

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
        for index in range(other.entry_count):
            comptime if Self.destructive:
                if other._is_deleted(index):
                    continue
            self.put(other._key_at(index), other._values[unsafe_offset=index])

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
        while current < self.entry_count:
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
            if self.entry_count >= MAX_ENTRIES:
                abort(
                    String(
                        "StringDict: ",
                        MAX_ENTRIES,
                        (
                            " entries is all this KeyCountType can index, and"
                            " this is entry "
                        ),
                        self.entry_count + 1,
                        (
                            ". Widen KeyCountType. Deleted entries count, since"
                            " they are never renumbered."
                        ),
                    )
                )
        var index = self.entry_count
        self._reserve_entry(index)
        # Hoisted after the reserve, the only thing that can move them. All
        # four regions share one allocation, so as far as the compiler knows a
        # store through any of them could alias a load of the others' fields,
        # and it would reload each on every use.
        var ends = self.keys_end
        var values = self._values
        self._append_key(key, index, ends)
        values.unsafe_offset(index).unsafe_write(value.copy())
        comptime if Self.caching_hashes:
            self.entry_hashes.unsafe_store(
                index, Scalar[Self._HashCacheType](key_hash)
            )
        self.entry_count += 1
        self.count += 1
        if self.control[unsafe_offset=reusable] == _EMPTY:
            self.occupied += 1
        self._occupy(reusable, key_hash, self.entry_count)

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
            if self.entry_hashes[unsafe_offset=key_index - 1] != Scalar[
                Self._HashCacheType
            ](key_hash):
                return False
        return self._key_at(key_index - 1) == key

    @always_inline
    def _occupy(mut self, slot: Int, key_hash: UInt64, key_index: Int):
        """Writes an entry into a slot, deriving its tag from `key_hash`."""
        self._place(slot, Self._tag(key_hash), key_index)

    @always_inline
    def _place(mut self, slot: Int, tag: UInt8, key_index: Int):
        """Writes an entry into a slot, control byte and mirror included.

        Takes the tag rather than the hash, so a rehash can carry over the byte
        an entry already had instead of recomputing it.

        Args:
            slot: The slot to fill.
            tag: The seven hash bits that go in the control byte.
            key_index: The one-based entry index.
        """
        self.slot_to_index.unsafe_store(
            slot, Scalar[Self.KeyCountType](key_index)
        )
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
        var old_ends = self.keys_end
        var old_hashes = self.entry_hashes
        var old_mask = self.deleted_mask

        var grown = old_capacity
        while grown <= index:
            # By half rather than by doubling: this block carries the values
            # and the key end offsets, which is most of what an entry costs,
            # and overshooting by half wastes a third less in a container
            # chosen for footprint. The `+ 1` keeps the step positive at one.
            grown += (grown >> 1) + 1
        self.entry_capacity = grown
        self.entries = Self._alloc_entries(grown)
        self._bind_entries()

        # Values may own memory, so they are moved rather than copied; the
        # hashes and the mask are plain bytes.
        unsafe_uninit_move_n[overlapping=False](
            dest=self._values, src=old_values, count=self.entry_count
        )
        unsafe_memcpy(dest=self.keys_end, src=old_ends, count=self.entry_count)
        comptime if Self.caching_hashes:
            unsafe_memcpy(
                dest=self.entry_hashes,
                src=old_hashes,
                count=self.entry_count,
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
            var tag: UInt8
            var slot: Int
            comptime CACHED_SLOTS = 1 << (
                size_of[Scalar[Self._HashCacheType]]() * 8
            )
            comptime if Self.caching_hashes:
                if self.capacity <= CACHED_SLOTS:
                    # The entry already carries its tag in the byte it
                    # occupied, so the top of the hash is never needed here --
                    # which is why the cached low bits suffice.
                    tag = old_control[unsafe_offset=i]
                    slot = Int(
                        self.entry_hashes[unsafe_offset=key_index - 1]
                        & Scalar[Self._HashCacheType](mask)
                    )
                else:
                    # One doubling past what the cached bits can address; only
                    # reachable with a narrow `KeyCountType`.
                    var key_hash = hash(self._key_at(key_index - 1))
                    tag = Self._tag(key_hash)
                    slot = Int(key_hash & UInt64(mask))
            else:
                var key_hash = hash(self._key_at(key_index - 1))
                tag = Self._tag(key_hash)
                slot = Int(key_hash & UInt64(mask))
            var control = self.control
            while True:
                var group = control.unsafe_offset(slot).unsafe_load[
                    width=GROUP
                ]()
                var lane = Self._first_lane(
                    group.eq(SIMD[DType.uint8, GROUP](_EMPTY))
                )
                if lane != GROUP:
                    self._place((slot + lane) & mask, tag, key_index)
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
        unsafe_destroy_n(self._values, self.entry_count)
        self.entry_count = 0
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
        var borrowed = self._src[]._key_at(index)
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
        var borrowed = self._src[]._key_at(index)
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
