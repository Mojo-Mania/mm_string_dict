from mm_string_dict import KeysContainer, StringDict
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
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
    assert_equal(StringDict[Int](capacity=1).capacity, 8)
    assert_equal(StringDict[Int](capacity=16).capacity, 16)
    assert_equal(StringDict[Int](capacity=17).capacity, 32)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
