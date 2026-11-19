import hashlib
import struct
import unittest
from pathlib import Path

from build import ALPHABET, compile_words


class WordCompilerTests(unittest.TestCase):
    def lookup(self, data, word):
        index = 0
        for ch in word:
            _, children, _, first, _ = struct.unpack_from("<BBHII", data, 24 + index * 12)
            matches = [child for child in range(first, first + children)
                       if data[24 + child * 12] == ALPHABET.index(ch)]
            if not matches:
                return None
            index = matches[0]
        return struct.unpack_from("<I", data, 24 + index * 12 + 8)[0] or None

    def test_deterministic_and_unicode_preserved(self):
        a = compile_words("straße 10\ngrüße 20\nhallo 30\n".encode(), "de")
        b = compile_words("hallo 30\nstraße 10\ngrüße 20\n".encode(), "de")
        self.assertEqual(a, b)
        self.assertEqual(self.lookup(a, "straße"), 10)
        self.assertEqual(self.lookup(a, "grüße"), 20)
        self.assertIsNone(self.lookup(a, "strasse"))

    def test_filters_without_case_or_digraph_guessing(self):
        data = compile_words("hello 10\nHello 20\nhi 30\ncan't 40\na-b 50\nfür 60\na 70\n".encode(), "en")
        self.assertEqual(struct.unpack_from("<I", data, 8)[0], 2)
        self.assertEqual(self.lookup(data, "hello"), 10)
        self.assertEqual(self.lookup(data, "hi"), 30)
        self.assertIsNone(self.lookup(data, "a"))

    def test_rejects_invalid_counts_and_large_inputs(self):
        for raw in [b"hello 0", b"hello -1", b"hello 4294967296", b"hello nope", b"bad"]:
            with self.assertRaises(ValueError):
                compile_words(raw, "en")
        with self.assertRaises(ValueError):
            compile_words(b"hello 1\n" * 50_001, "en")

    def test_committed_resources_integrity_and_forward_only_tree(self):
        root = Path(__file__).resolve().parents[2] / "TyprShared/FullKeyboard/WordData"
        expected = {
            "de": "9f44e7e6d71f1f214528f2a140743b65c2e798fda2cfe88775a6738b13c290e8",
            "en": "ca0cf23d3ef0bddf0f633a20aa82d05e667dd848f35cc773f0531609f5903ff8",
        }
        for language, digest in expected.items():
            data = (root / f"keyboard-{language}.words").read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
            magic, nodes, words, reserved, total = struct.unpack_from("<4sIIIQ", data)
            self.assertEqual(magic, b"TSW1")
            self.assertEqual(reserved, 0)
            self.assertEqual(len(data), 24 + 12 * nodes)
            self.assertLess(len(data), 5_000_000)
            terminal_counts = []
            parents = [0] * nodes
            for index in range(nodes):
                label, count, padding, first, frequency = struct.unpack_from("<BBHII", data, 24 + 12 * index)
                self.assertEqual(padding, 0)
                self.assertLessEqual(frequency, total)
                self.assertTrue(label == 255 if index == 0 else label < len(ALPHABET))
                self.assertLessEqual(count, len(ALPHABET))
                if count:
                    self.assertGreater(first, index)
                    self.assertLessEqual(first + count, nodes)
                    labels = []
                    for child in range(first, first + count):
                        parents[child] += 1
                        labels.append(data[24 + 12 * child])
                    self.assertEqual(labels, sorted(set(labels)))
                else:
                    self.assertEqual(first, 0)
                if frequency:
                    terminal_counts.append(frequency)
            self.assertEqual(parents, [0] + [1] * (nodes - 1))
            self.assertEqual(len(terminal_counts), words)
            self.assertEqual(sum(terminal_counts), total)
            self.assertIsNotNone(self.lookup(data, "straße" if language == "de" else "keyboard"))


if __name__ == "__main__":
    unittest.main()
