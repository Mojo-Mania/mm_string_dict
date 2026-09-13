from corpora import load, names
from mm_string_dict import GROUP, KeysContainer, StringDict
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)


# ===-----------------------------------------------------------------------===#
# KeysContainer
# ===-----------------------------------------------------------------------===#


def test_keys_container_stores_and_returns() raises:
    var keys = KeysContainer[DType.uint32](8)
    keys.add("alpha")
    keys.add("beta")
    keys.add("")
    keys.add("gamma")
    assert_equal(len(keys), 4)
    assert_equal(String(keys[0]), "alpha")
    assert_equal(String(keys[1]), "beta")
    assert_equal(String(keys[2]), "")
    assert_equal(String(keys[3]), "gamma")


def test_keys_container_out_of_range_is_empty() raises:
    var keys = KeysContainer[DType.uint32](8)
    keys.add("only")
    assert_equal(String(keys[-1]), "")
    assert_equal(String(keys[1]), "")


def test_keys_container_grows_its_byte_buffer() raises:
    var keys = KeysContainer[DType.uint32](4)
    var long = String("x") * 500
    for i in range(20):
        keys.add(String(long, i))
    assert_equal(len(keys), 20)
    for i in range(20):
        assert_equal(String(keys[i]), String(long, i))


def test_keys_container_clear_and_reuse() raises:
    var keys = KeysContainer[DType.uint32](8)
    keys.add("alpha")
    keys.clear()
    assert_equal(len(keys), 0)
    keys.add("beta")
    assert_equal(len(keys), 1)
    assert_equal(String(keys[0]), "beta")


def test_keys_container_copy_is_independent() raises:
    var keys = KeysContainer[DType.uint32](8)
    keys.add("alpha")
    var duplicate = keys.copy()
    keys.add("beta")
    assert_equal(len(duplicate), 1)
    assert_equal(len(keys), 2)
    assert_equal(String(duplicate[0]), "alpha")


# ===-----------------------------------------------------------------------===#
# Basics
# ===-----------------------------------------------------------------------===#


def test_empty() raises:
    var dict = StringDict[Int]()
    assert_equal(len(dict), 0)
    assert_false("anything" in dict)
    assert_equal(dict.get("anything", -1), -1)


def test_put_and_get() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.put("pear", 2)
    assert_equal(len(dict), 2)
    assert_equal(dict.get("apple", -1), 1)
    assert_equal(dict.get("pear", -1), 2)
    assert_true("apple" in dict)
    assert_false("plum" in dict)


def test_put_replaces_the_value() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.put("apple", 9)
    assert_equal(len(dict), 1, "replacing must not add an entry")
    assert_equal(dict.get("apple", -1), 9)


def test_empty_string_key() raises:
    var dict = StringDict[Int]()
    dict.put("", 7)
    assert_equal(dict.get("", -1), 7)
    assert_true("" in dict)
    assert_equal(len(dict), 1)


def test_unicode_keys() raises:
    var dict = StringDict[Int]()
    dict.put("möwe", 1)
    dict.put("🔥", 2)
    dict.put("日本語", 3)
    assert_equal(dict.get("möwe", -1), 1)
    assert_equal(dict.get("🔥", -1), 2)
    assert_equal(dict.get("日本語", -1), 3)
    assert_equal(len(dict), 3)


def test_long_keys() raises:
    var dict = StringDict[Int]()
    var long = String("k") * 2000
    dict.put(long, 1)
    dict.put(String(long, "-other"), 2)
    assert_equal(dict.get(long, -1), 1)
    assert_equal(dict.get(String(long, "-other"), -1), 2)


def test_string_values() raises:
    var dict = StringDict[String]()
    dict.put("greeting", "hello")
    dict.put("farewell", "goodbye")
    assert_equal(dict.get("greeting", ""), "hello")
    assert_equal(dict.get("missing", "default"), "default")


def test_clear() raises:
    var dict = StringDict[Int]()
    for i in range(50):
        dict.put(String("key-", i), i)
    dict.clear()
    assert_equal(len(dict), 0)
    assert_false("key-1" in dict)
    dict.put("fresh", 1)
    assert_equal(len(dict), 1)
    assert_equal(dict.get("fresh", -1), 1)


def test_copy_is_independent() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    var duplicate = dict.copy()
    dict.put("pear", 2)
    duplicate.put("plum", 3)
    assert_equal(len(dict), 2)
    assert_equal(len(duplicate), 2)
    assert_false("plum" in dict)
    assert_false("pear" in duplicate)


# ===-----------------------------------------------------------------------===#
# Growth
# ===-----------------------------------------------------------------------===#


def test_growth_keeps_every_entry() raises:
    var dict = StringDict[Int]()
    for i in range(1000):
        dict.put(String("key-", i), i)
    assert_equal(len(dict), 1000)
    for i in range(1000):
        assert_equal(dict.get(String("key-", i), -1), i)
    assert_false("key-1000" in dict)


def test_small_initial_capacity() raises:
    var dict = StringDict[Int](capacity=1)
    for i in range(100):
        dict.put(String("key-", i), i)
    assert_equal(len(dict), 100)
    for i in range(100):
        assert_equal(dict.get(String("key-", i), -1), i)


def test_capacity_is_rounded_to_a_power_of_two() raises:
    """The floor is one SIMD group, since a probe scans a whole group."""
    assert_equal(StringDict[Int](capacity=1).capacity, GROUP)
    assert_equal(StringDict[Int](capacity=GROUP).capacity, GROUP)
    assert_equal(StringDict[Int](capacity=GROUP * 2).capacity, GROUP * 2)
    assert_equal(StringDict[Int](capacity=GROUP * 2 + 1).capacity, GROUP * 4)


# ===-----------------------------------------------------------------------===#
# Deletion
# ===-----------------------------------------------------------------------===#


def test_delete() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.put("pear", 2)
    dict.delete("apple")
    assert_equal(len(dict), 1)
    assert_equal(dict.get("apple", -1), -1)
    assert_false("apple" in dict, "a deleted key must not report as present")
    assert_equal(dict.get("pear", -1), 2)


def test_delete_missing_key_is_a_no_op() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.delete("plum")
    assert_equal(len(dict), 1)


def test_delete_twice_counts_once() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.delete("apple")
    dict.delete("apple")
    assert_equal(len(dict), 0)


def test_reinserting_a_deleted_key_revives_it() raises:
    var dict = StringDict[Int]()
    dict.put("apple", 1)
    dict.delete("apple")
    dict.put("apple", 5)
    assert_equal(len(dict), 1)
    assert_equal(dict.get("apple", -1), 5)
    assert_true("apple" in dict)


def test_delete_heavy_churn_terminates() raises:
    """Regression: the rehash trigger counted live entries, but deleting does
    not free a slot. Once occupied slots reached capacity, `put` probed for an
    empty slot that no longer existed and spun forever."""
    var dict = StringDict[Int]()
    for i in range(100):
        dict.put(String("key-", i), i)
    for i in range(100):
        dict.delete(String("key-", i))
    assert_equal(len(dict), 0)
    for i in range(100, 300):
        dict.put(String("key-", i), i)
    assert_equal(len(dict), 200)
    for i in range(100, 300):
        assert_equal(dict.get(String("key-", i), -1), i)
    for i in range(100):
        assert_false(String("key-", i) in dict)


def test_non_destructive_ignores_delete() raises:
    var dict = StringDict[Int, DType.uint32, DType.uint32, False]()
    dict.put("apple", 1)
    dict.delete("apple")
    assert_equal(len(dict), 1, "delete does nothing when destructive is off")
    assert_equal(dict.get("apple", -1), 1)


# ===-----------------------------------------------------------------------===#
# upsert
# ===-----------------------------------------------------------------------===#


def test_upsert_inserts_when_absent() raises:
    var dict = StringDict[Int]()

    def start(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    dict.upsert("hits", start)
    assert_equal(dict.get("hits", -1), 1)


def test_upsert_updates_when_present() raises:
    var dict = StringDict[Int]()

    def bump(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    for _ in range(5):
        dict.upsert("hits", bump)
    assert_equal(dict.get("hits", -1), 5)
    assert_equal(len(dict), 1)


def test_upsert_after_delete_starts_over() raises:
    var dict = StringDict[Int]()

    def bump(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    dict.upsert("hits", bump)
    dict.upsert("hits", bump)
    dict.delete("hits")
    dict.upsert("hits", bump)
    assert_equal(dict.get("hits", -1), 1, "a revived entry starts fresh")
    assert_equal(len(dict), 1)


# ===-----------------------------------------------------------------------===#
# Parameters
# ===-----------------------------------------------------------------------===#


def test_without_cached_hashes() raises:
    var dict = StringDict[Int, DType.uint32, DType.uint32, True, False]()
    for i in range(500):
        dict.put(String("key-", i), i)
    for i in range(500):
        assert_equal(dict.get(String("key-", i), -1), i)
    dict.delete("key-3")
    assert_false("key-3" in dict)
    assert_equal(len(dict), 499)


def test_narrow_key_count_type() raises:
    var dict = StringDict[Int, DType.uint16]()
    for i in range(1000):
        dict.put(String("key-", i), i)
    assert_equal(len(dict), 1000)
    for i in range(1000):
        assert_equal(dict.get(String("key-", i), -1), i)


def test_narrow_key_offset_type() raises:
    var dict = StringDict[Int, DType.uint32, DType.uint16]()
    for i in range(500):
        dict.put(String("key-", i), i)
    assert_equal(len(dict), 500)
    for i in range(500):
        assert_equal(dict.get(String("key-", i), -1), i)


# ===-----------------------------------------------------------------------===#
# Cross-check against the stdlib Dict
# ===-----------------------------------------------------------------------===#


def test_random_operations_against_a_reference() raises:
    """Mirrors every operation into a `Dict` and compares after each step."""
    var dict = StringDict[Int]()
    var reference = Dict[String, Int]()
    var state = 12345

    for step in range(3000):
        state ^= state << 13
        state &= 0xFFFF_FFFF_FFFF_FFFF
        state ^= state >> 7
        state ^= state << 17
        state &= 0xFFFF_FFFF_FFFF_FFFF
        var key = String("k", state % 400)

        if step % 5 == 4:
            dict.delete(key)
            try:
                _ = reference.pop(key)
            except:
                pass
        else:
            dict.put(key, step)
            reference[key] = step

        assert_equal(len(dict), len(reference), String("after step ", step))

    for entry in reference.items():
        assert_equal(
            dict.get(entry.key, -1),
            entry.value,
            String("wrong value for ", entry.key),
        )
        assert_true(entry.key in dict)


# ===-----------------------------------------------------------------------===#
# The Dict-shaped surface
# ===-----------------------------------------------------------------------===#


def test_subscript_get_and_set() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    dict["pear"] = 2
    assert_equal(dict["apple"], 1)
    assert_equal(dict["pear"], 2)
    dict["apple"] = 9
    assert_equal(dict["apple"], 9)
    assert_equal(len(dict), 2)


def test_subscript_raises_on_a_missing_key() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    with assert_raises():
        _ = dict["plum"]
    dict.delete("apple")
    with assert_raises():
        _ = dict["apple"]


def test_bool() raises:
    var dict = StringDict[Int]()
    assert_false(Bool(dict))
    dict["apple"] = 1
    assert_true(Bool(dict))
    dict.delete("apple")
    assert_false(Bool(dict))


def test_keys_values_items() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    dict["pear"] = 2
    dict["plum"] = 3

    var keys = List[String]()
    for key in dict.keys():
        keys.append(String(key))
    assert_equal(len(keys), 3)
    assert_equal(keys[0], "apple")
    assert_equal(keys[2], "plum")

    var total = 0
    for value in dict.values():
        total += value
    assert_equal(total, 6)

    var pairs = 0
    for entry in dict.items():
        pairs += 1
        assert_equal(dict[entry.key], entry.value)
    assert_equal(pairs, 3)


def test_iteration_yields_keys() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    dict["pear"] = 2
    var seen = List[String]()
    for key in dict:
        seen.append(String(key))
    assert_equal(len(seen), 2)
    assert_equal(seen[0], "apple")


def test_iteration_skips_deleted_entries() raises:
    var dict = StringDict[Int]()
    for i in range(10):
        dict[String("key-", i)] = i
    for i in range(0, 10, 2):
        dict.delete(String("key-", i))
    var seen = 0
    var total = 0
    for entry in dict.items():
        seen += 1
        total += entry.value
    assert_equal(seen, 5)
    assert_equal(total, 1 + 3 + 5 + 7 + 9)


def test_iteration_over_an_empty_dict() raises:
    var dict = StringDict[Int]()
    var seen = 0
    for _ in dict.keys():
        seen += 1
    assert_equal(seen, 0)


def test_values_are_references() raises:
    var dict = StringDict[String]()
    dict["greeting"] = "hello"
    for value in dict.values():
        assert_equal(value, "hello")


def test_pop() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    dict["pear"] = 2
    assert_equal(dict.pop("apple"), 1)
    assert_equal(len(dict), 1)
    assert_false("apple" in dict)
    with assert_raises():
        _ = dict.pop("apple")
    assert_equal(dict.pop("nope", -1), -1)
    assert_equal(dict.pop("pear", -1), 2)
    assert_equal(len(dict), 0)


def test_setdefault() raises:
    var dict = StringDict[Int]()
    assert_equal(dict.setdefault("apple", 1), 1)
    assert_equal(dict.setdefault("apple", 99), 1, "must not overwrite")
    assert_equal(len(dict), 1)
    dict.delete("apple")
    assert_equal(dict.setdefault("apple", 7), 7, "a deleted key is absent")
    assert_equal(len(dict), 1)


def test_update() raises:
    var dict = StringDict[Int]()
    dict["apple"] = 1
    dict["pear"] = 2
    var other = StringDict[Int]()
    other["pear"] = 20
    other["plum"] = 30
    other["kiwi"] = 40
    other.delete("kiwi")
    dict.update(other)
    assert_equal(len(dict), 3, "deleted entries are not carried over")
    assert_equal(dict["apple"], 1)
    assert_equal(dict["pear"], 20)
    assert_equal(dict["plum"], 30)
    assert_false("kiwi" in dict)


def test_key_bytes_reports_the_packed_buffer() raises:
    var dict = StringDict[Int]()
    for i in range(100):
        dict[String("key-", i)] = i
    assert_true(dict.key_bytes() > 0)


# ===-----------------------------------------------------------------------===#
# Real corpora
#
# The tests above use generated keys, which are uniform in length, all ASCII,
# and never repeat. Real words are none of those things, and the bugs that
# survive synthetic tests tend to live in exactly that gap: multi-byte UTF-8,
# one-character keys, keys that differ only in a trailing byte, and the same
# word arriving hundreds of times. The corpora come from
# github.com/mzaks/compact-dict.
# ===-----------------------------------------------------------------------===#


def test_corpus_word_counts_match_a_reference_dict() raises:
    """Counts every corpus twice and requires the two tallies to agree."""

    def bump(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    for name in names():
        var words = load(name)
        var dict = StringDict[Int]()
        var reference = Dict[String, Int]()
        for i in range(len(words)):
            dict.upsert(words[i], bump)
            reference[words[i]] = reference.get(words[i], 0) + 1

        assert_equal(len(dict), len(reference), name)
        for entry in reference.items():
            assert_equal(dict.get(entry.key, 0), entry.value, name)


def test_corpus_every_word_is_found() raises:
    """Every stored word is present; words in another script are not."""
    for name in names():
        var words = load(name)
        var dict = StringDict[Int]()
        for i in range(len(words)):
            dict[words[i]] = i
        for i in range(len(words)):
            assert_true(words[i] in dict, name)

        var absent = load("georgian" if name != "georgian" else "hindi")
        for i in range(len(absent)):
            if absent[i] not in dict:
                assert_equal(dict.get(absent[i], -1), -1, name)


def test_corpus_keys_round_trip_byte_for_byte() raises:
    """Keys come back out of the packed buffer exactly as they went in.

    Greek, Hebrew, Arabic, Georgian, Devanagari and CJK keys are multi-byte, so
    an off-by-one in the end-offset array shows up here as a mangled key rather
    than as a missing one.
    """
    for name in names():
        var words = load(name)
        var dict = StringDict[Int]()
        var distinct = Dict[String, Bool]()
        for i in range(len(words)):
            dict[words[i]] = i
            distinct[words[i]] = True

        var seen = Dict[String, Bool]()
        for key in dict.keys():
            var owned = String(key)
            assert_true(owned in distinct, String(name, ": stray key ", owned))
            assert_false(owned in seen, String(name, ": duplicate key ", owned))
            seen[owned] = True
        assert_equal(len(seen), len(distinct), name)


def test_corpus_values_survive_deletion_of_every_other_word() raises:
    """Deletes half the distinct words and checks both halves afterwards."""
    for name in names():
        var words = load(name)
        var dict = StringDict[Int]()
        var distinct = List[String]()
        for i in range(len(words)):
            if words[i] not in dict:
                distinct.append(words[i])
            dict[words[i]] = i

        for i in range(0, len(distinct), 2):
            dict.delete(distinct[i])
        assert_equal(len(dict), len(distinct) - ((len(distinct) + 1) // 2))

        for i in range(len(distinct)):
            if i % 2 == 0:
                assert_false(distinct[i] in dict, name)
            else:
                assert_true(distinct[i] in dict, name)

        # Reinserting must reuse the vacated slots, not leak them.
        for i in range(0, len(distinct), 2):
            dict[distinct[i]] = -i
        assert_equal(len(dict), len(distinct), name)
        for i in range(0, len(distinct), 2):
            assert_equal(dict.get(distinct[i], 1), -i, name)


def test_corpus_keys_are_stored_end_to_end() raises:
    """The packed buffer holds each distinct key once, with no per-key header.

    English is 999 words but only 192 distinct ones, so a buffer that grew with
    every `put` rather than with every new key would be several times larger
    than the keys need.
    """
    var words = load("english")
    var dict = StringDict[Int]()
    var needed = 0
    for i in range(len(words)):
        if words[i] not in dict:
            needed += words[i].byte_length()
        dict[words[i]] = i

    assert_equal(len(dict), 192)
    assert_true(dict.key_bytes() >= needed, "buffer is too small for the keys")
    # Slack is whatever the last growth step over-allocated, never per-key
    # overhead, so it cannot reach a second full copy of the keys.
    assert_true(
        dict.key_bytes() < needed * 2,
        String("buffer ", dict.key_bytes(), " for ", needed, " bytes of keys"),
    )


def test_tombstones_survive_mask_growth() raises:
    """Deletes while the mask is still growing, then checks every bit.

    The tombstone mask is reallocated as entries accumulate, so a bit set early
    has to be carried across several reallocations. Deleting as we insert,
    rather than after, is what puts bits below the mask's current end before it
    grows again.
    """
    var dict = StringDict[Int]()
    var live = Dict[String, Int]()
    for i in range(5000):
        var key = String("key-", i)
        dict[key] = i
        live[key] = i
        if i % 7 == 0:
            dict.delete(key)
            _ = live.pop(key)

    assert_equal(len(dict), len(live))
    for i in range(5000):
        var key = String("key-", i)
        if i % 7 == 0:
            assert_false(key in dict, key)
        else:
            assert_equal(dict.get(key, -1), i, key)

    # Iteration walks entries and consults the mask directly, so it is the
    # reader that a lost bit would show up in.
    var seen = 0
    for entry in dict.items():
        assert_equal(live.get(String(entry.key), -1), entry.value)
        seen += 1
    assert_equal(seen, len(live))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
