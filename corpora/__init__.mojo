"""Real-world word lists, for benchmarks and tests that are not synthetic.

Each corpus is a text file split on whitespace into a list of words. They come
from https://github.com/mzaks/compact-dict, where this dictionary started, and
they matter because random fixed-length keys hide the things real keys do:
repeat, vary in length, and run to several bytes per character.

```mojo
from corpora import load, names

var words = load("greek")
```

Paths are resolved from the working directory, so run from the repository root
-- which is what `pixi run test` and `pixi run bench` do.
"""

from std.pathlib import cwd


def names() -> List[String]:
    """Returns every corpus name, roughly by how much UTF-8 they use.

    Returns:
        The names accepted by `load`.
    """
    return [
        String("english"),
        "french",
        "german",
        "l33t",
        "s3_actions",
        "greek",
        "hebrew",
        "arabic",
        "georgian",
        "hindi",
        "chinese",
        "japanese",
    ]


def load(name: StringSlice) raises -> List[String]:
    """Returns the words of one corpus, in the order they appear.

    Words repeat, which is the point: a real key distribution is not a set of
    distinct random strings.

    Args:
        name: The corpus name, one of `NAMES`.

    Raises:
        Error: If the corpus file cannot be read.

    Returns:
        The words, including duplicates.
    """
    var text = (cwd() / "corpora" / String(name, ".txt")).read_text()
    var words = List[String]()
    for piece in text.replace("\n", " ").split(" "):
        if piece.byte_length() != 0:
            words.append(String(piece))
    return words^


@fieldwise_init
struct Stats(Copyable, Movable, Writable):
    """What a corpus looks like, for reporting alongside a measurement."""

    var words: Int
    """How many words, duplicates included."""
    var distinct: Int
    """How many distinct words."""
    var shortest: Int
    """The shortest key, in bytes."""
    var longest: Int
    """The longest key, in bytes."""
    var bytes: Int
    """Every key's bytes added up, duplicates included."""

    def write_to(self, mut writer: Some[Writer]):
        """Writes the statistics as one line.

        Args:
            writer: The writer to write to.
        """
        writer.write(
            self.words,
            " words, ",
            self.distinct,
            " distinct, ",
            self.bytes // self.words,
            " bytes avg (",
            self.shortest,
            "-",
            self.longest,
            ")",
        )


def describe(words: List[String]) raises -> Stats:
    """Measures a corpus.

    Args:
        words: The words to describe.

    Returns:
        The statistics.
    """
    var shortest = 1 << 30
    var longest = 0
    var total = 0
    var seen = Dict[String, Bool]()
    for word in words:
        var length = word.byte_length()
        total += length
        if length < shortest:
            shortest = length
        if length > longest:
            longest = length
        seen[word] = True
    return Stats(len(words), len(seen), shortest, longest, total)
