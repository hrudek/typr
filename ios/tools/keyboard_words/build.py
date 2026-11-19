#!/usr/bin/env python3
"""Explicit offline compiler for pinned FrequencyWords inputs; never downloads data."""
import argparse
import hashlib
import struct
import unicodedata
from pathlib import Path

REVISION = "525f9b560de45753a5ea01069454e72e9aa541c6"
ALPHABET = "abcdefghijklmnopqrstuvwxyzäöüß"
SOURCE_SHA256 = {
    "de": "d9e50546fd7e8b6fe6542a2b33c51d1331092b2a3916ec09f80d97856068705b",
    "en": "5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458",
}


def compile_words(raw: bytes, language: str) -> bytes:
    lines = raw.decode("utf-8").splitlines()
    if len(lines) > 50_000:
        raise ValueError("at most 50,000 source entries")
    words = {}
    allowed = set(ALPHABET if language == "de" else ALPHABET[:26])
    for line in lines:
        word, count = line.rsplit(" ", 1)
        count = int(count)
        if count <= 0 or count > 0xFFFFFFFF:
            raise ValueError("invalid count")
        # No accent stripping, case guessing, digraph expansion or word synthesis.
        word = unicodedata.normalize("NFC", word)
        if 2 <= len(word) <= 32 and set(word) <= allowed:
            words[word] = words.get(word, 0) + count
    root = [{}, 0]
    for word, count in sorted(words.items()):
        node = root
        for ch in word:
            node = node[0].setdefault(ALPHABET.index(ch), [{}, 0])
        node[1] = count
    # Breadth-first, contiguous children, 12 bytes/node. The root has label 255.
    nodes = [(255, root)]
    records = bytearray()
    cursor = 0
    while cursor < len(nodes):
        label, (children, count) = nodes[cursor]
        first = len(nodes) if children else 0
        nodes.extend(sorted(children.items()))
        records.extend(struct.pack("<BBHII", label, len(children), 0, first, count))
        cursor += 1
    total = sum(words.values())
    return struct.pack("<4sIIIQ", b"TSW1", len(nodes), len(words), 0, total) + records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", choices=["de", "en"])
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    raw = args.input.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256[args.language]:
        parser.error("input does not match the reviewed source revision")
    result = compile_words(raw, args.language)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(result)
    print(f"{args.language}: source sha256={hashlib.sha256(raw).hexdigest()}")
    print(f"resource sha256={hashlib.sha256(result).hexdigest()}, bytes={len(result)}")


if __name__ == "__main__":
    main()
