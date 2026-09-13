# Corpora

Word lists used by the tests and benchmarks, from
[mzaks/compact-dict](https://github.com/mzaks/compact-dict), where this
dictionary started.

Each file is plain UTF-8 text; `load(name)` splits it on whitespace. Load them
with `from corpora import describe, load, names` and run from the repository
root, since paths resolve from the working directory.

| file | words | distinct | avg bytes | range | what it exercises |
| --- | --- | --- | --- | --- | --- |
| `english.txt` | 999 | 192 | 4 | 1–13 | heavy repetition, one-byte keys |
| `german.txt` | 999 | 208 | 5 | 2–18 | heavy repetition, umlauts |
| `l33t.txt` | 487 | 339 | 4 | 2–14 | digits and punctuation in keys |
| `french.txt` | 471 | 418 | 6 | 2–19 | accented Latin, mostly distinct |
| `greek.txt` | 452 | 320 | 10 | 3–28 | two-byte codepoints |
| `arabic.txt` | 463 | 336 | 9 | 2–26 | two-byte, right-to-left |
| `hebrew.txt` | 376 | 231 | 8 | 2–25 | two-byte, right-to-left |
| `hindi.txt` | 450 | 250 | 18 | 9–51 | three-byte Devanagari |
| `georgian.txt` | 381 | 250 | 15 | 6–42 | three-byte Mkhedruli |
| `s3_actions.txt` | 161 | 143 | 22 | 8–43 | long ASCII identifiers with shared prefixes |
| `chinese.txt` | 10 | 10 | 464 | 441–480 | very long keys |
| `japanese.txt` | 10 | 10 | 499 | 378–558 | very long keys |

The Chinese and Japanese files are the odd ones out: neither language separates
words with spaces, so splitting on whitespace yields ten whole paragraphs of
400–560 bytes rather than ten words. That makes them a useful long-key case and
a poor per-word one — the benchmarks report building as time per corpus partly
for that reason.
