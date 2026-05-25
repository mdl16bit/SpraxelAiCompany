#!/usr/bin/env python3
"""slugify — turn an item title into a kebab-case slug suitable for branch names.

Examples:
    "[bug] p0 Stairs teleport on save/load" → "stairs-teleport-on-save-load"
    "Add a 'run' button that lets you run" → "add-run-button-that-lets-you-run"

Usage:
    echo "title" | slugify.py
    slugify.py "title"
"""
import re
import sys


STOP_WORDS = {"a", "an", "the", "and", "or", "of", "to", "for"}


def slugify(text: str, max_len: int = 50) -> str:
    # Strip leading tags like [bug], [feature], pN.
    text = re.sub(r"^\s*(\[[a-z-]+\]\s*)+", "", text, flags=re.I)
    text = re.sub(r"^\s*p[0-3]\s+", "", text, flags=re.I)
    # Lower, ASCII-ify roughly.
    text = text.lower()
    text = re.sub(r"[^\w\s-]", " ", text)
    # Drop stop words.
    words = [w for w in text.split() if w and w not in STOP_WORDS]
    slug = "-".join(words)
    # Compress repeated dashes.
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    # Truncate to max_len at a word boundary.
    if len(slug) > max_len:
        slug = slug[:max_len].rsplit("-", 1)[0] or slug[:max_len]
    return slug or "item"


def main() -> int:
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
    else:
        text = sys.stdin.read()
    print(slugify(text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
