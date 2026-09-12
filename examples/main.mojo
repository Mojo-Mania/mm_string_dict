"""A short tour of `StringDict`."""

from mm_string_dict import StringDict


def main() raises:
    # Counting words, the canonical use.
    var text = "the quick brown fox jumps over the lazy dog the fox"
    var counts = StringDict[Int]()

    def bump(value: Optional[Int]) -> Int:
        return value.value() + 1 if value else 1

    for word in text.split(" "):
        counts.upsert(word, bump)

    print("distinct words:", len(counts))
    print("the:", counts.get("the", 0), " fox:", counts.get("fox", 0))
    print("cat:", counts.get("cat", 0), "(absent, so the default)")

    # The keys live end to end in one buffer; here they are.
    print("\nkeys as stored:")
    counts.print_keys()

    # Deleting tombstones an entry; putting it back revives it.
    counts.delete("the")
    print(
        "\nafter deleting 'the':",
        len(counts),
        "entries, 'the' in counts:",
        "the" in counts,
    )
    counts.put("the", 99)
    print(
        "after putting it back:",
        len(counts),
        "entries, the =",
        counts.get("the", 0),
    )

    # Values can be anything copyable.
    var homes = StringDict[String]()
    homes.put("mojo", "modular")
    homes.put("swift", "apple")
    print("\nmojo comes from", homes.get("mojo", "?"))

    # A map that never deletes needs no tombstone bitmap.
    var lean = StringDict[Int, DType.uint32, DType.uint32, False]()
    lean.put("only", 1)
    print("non-destructive map:", lean.get("only", 0))
