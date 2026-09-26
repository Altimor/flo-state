#!/usr/bin/env python3
"""Generate the synthetic sample workspace the oracle runs against.

    python3 oracle/make_sandbox.py [dest]    (default: oracle/sandbox/Sample)

Everything is generated deterministically, so fixtures recorded from it are
reproducible. The workspace covers what the editor and the app shell render:
headings, bullet/task/ordered lists, links and wiki links, a table, code,
quotes, frontmatter, an emoji file name, an image attachment, a nested
`Archive/` folder and a long (~110 KB) dated journal with `## yyyy.mm.dd`
sections.
"""
import datetime
import random
import shutil
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT = HERE / "sandbox" / "Sample"

WORDS = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et "
         "dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea "
         "commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur "
         "excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est "
         "laborum").split()


def sentence(rng, lo=6, hi=16):
    ws = [rng.choice(WORDS) for _ in range(rng.randint(lo, hi))]
    r = rng.random()
    if r < 0.08:
        i = rng.randrange(len(ws)); ws[i] = f"**{ws[i]}**"
    elif r < 0.14:
        i = rng.randrange(len(ws)); ws[i] = f"*{ws[i]}*"
    elif r < 0.18:
        i = rng.randrange(len(ws)); ws[i] = f"`{ws[i]}`"
    elif r < 0.21:
        i = rng.randrange(len(ws)); ws[i] = f"[{ws[i]}](https://example.com/{ws[i]})"
    elif r < 0.24:
        i = rng.randrange(len(ws)); ws[i] = rng.choice(["[[Notes]]", "[[Groceries]]", "[[Project Alpha]]"])
    s = " ".join(ws)
    return s[0].upper() + s[1:] + rng.choice([".", ".", ".", "?", "!"])


def paragraph(rng, n=None):
    return " ".join(sentence(rng) for _ in range(n or rng.randint(1, 4)))


def journal(target=110_000, seed=7):
    """A long dated notebook: `## yyyy.mm.dd` sections with mixed content."""
    rng = random.Random(seed)
    day = datetime.date(2024, 1, 1)
    out = ["# Journal", "", paragraph(rng, 2), ""]
    size = 0
    while size < target:
        out += [f"## {day:%Y.%m.%d}", ""]
        for _ in range(rng.randint(1, 4)):
            k = rng.random()
            if k < 0.35:
                out += [paragraph(rng), ""]
            elif k < 0.6:
                for _ in range(rng.randint(2, 5)):
                    out.append("* " + sentence(rng, 3, 10))
                    if rng.random() < 0.3:
                        out.append("  * " + sentence(rng, 3, 8))
                out.append("")
            elif k < 0.75:
                for _ in range(rng.randint(2, 4)):
                    out.append(f"- [{'x' if rng.random() < 0.4 else ' '}] " + sentence(rng, 2, 7))
                out.append("")
            elif k < 0.85:
                for i in range(rng.randint(2, 4)):
                    out.append(f"{i + 1}. " + sentence(rng, 3, 9))
                out.append("")
            elif k < 0.92:
                out += ["### " + " ".join(rng.choice(WORDS) for _ in range(rng.randint(1, 4))).capitalize(), "",
                        paragraph(rng, 1), ""]
            else:
                out += ["> " + sentence(rng), ""]
        day += datetime.timedelta(days=rng.randint(1, 3))
        size = sum(len(l.encode()) + 1 for l in out)
    return "\n".join(out).rstrip("\n") + "\n"


def png(width=120, height=80):
    """A small RGB gradient PNG (no dependencies)."""
    rows = b"".join(b"\x00" + bytes(v for x in range(width) for v in (x * 2 % 256, y * 3 % 256, 180))
                    for y in range(height))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


NOTES = """# Notes

A scratchpad for ideas that do not have a home yet. See [[Project Alpha]] and the [[Groceries]] list.

## Today

* Review the draft outline
* Reply to comments on the **design doc**
  * Mention the open question about *sync*
  * Link the [reference](https://example.com/reference)
* Tidy up the `attachments` folder

## Tasks

- [ ] Write the weekly summary
- [x] Book the meeting room
- [ ] Read [[📓 Reading log]]

## Steps

1. Collect the notes
2. Group them by topic
3. Archive what is done (see [[Archive/Old ideas]])

![Diagram](attachments/diagram.png)

---

Last line with ~~struck~~ text and a footnote-like remark.
"""

GROCERIES = """# Groceries

- [ ] Apples
- [ ] Bread
- [x] Coffee beans
- [ ] Olive oil
- [ ] Rice
- [x] Tomatoes

## Later

* Spices
* Tea
"""

PROJECT = """# Project Alpha

## Goals

1. Ship a first version
2. Measure how people use it
3. Decide what to build next

## Status

| Area | Owner | State |
|:-----|:-----:|------:|
| Editor | Sam | done |
| Sync | Alex | in progress |
| Search | Kim | planned |

## Notes

> Keep the scope small and the feedback loop short.

```python
def greet(name):
    return f"Hello, {name}!"
```

Math inline $e^{i\\pi} + 1 = 0$ and a [[Notes|link back]].
"""

MEETING = """---
title: Weekly sync
tags: meetings
status: draft
---
# Weekly sync

## Agenda

* Updates
* Risks
* Next steps

## Decisions

- [ ] Follow up on the open questions
"""

READING = """# Reading log

* *A Pattern Language* — chapters 1 to 3
* *The Design of Everyday Things* — done
* Articles saved in [[Notes]]
"""

FORMATTING = """# Formatting

Plain text with **bold**, *italic*, ***both***, ~~strike~~, `code`, ==highlight== and :smile:.

Links: [inline](https://example.com), <https://example.com/auto>, [[Groceries]], [[Project Alpha#Status]].

<div align="center">An HTML block</div>

$$
\\int_0^1 x^2 \\, dx = \\frac{1}{3}
$$

```mermaid
graph TD
  A[Start] --> B{Decide}
  B -->|yes| C[Do it]
  B -->|no| D[Skip]
```

    indented code block

* [ ] nested task
  1. ordered child
  2. another child
     * deep bullet
"""

FILES = {
    "Notes.md": NOTES,
    "Groceries.md": GROCERIES,
    "Project Alpha.md": PROJECT,
    "Weekly sync.md": MEETING,
    "📓 Reading log.md": READING,
    "Formatting.md": FORMATTING,
    "Master plan.md": "# Master plan\n\n1. Outline\n2. Draft\n3. Review\n",
    "Master notes.md": "# Master notes\n\n* Collected highlights from [[Journal]]\n",
    "Top ideas.md": "# Top ideas\n\n* A quieter sidebar\n* Faster search\n",
    "Growth/Growth experiments.md": "# Growth experiments\n\n- [ ] Try a shorter onboarding\n",
    "Archive/Old ideas.md": "# Old ideas\n\n* Things that did not make the cut\n* Kept for reference\n",
    "Archive/2023 review.md": "# 2023 review\n\n## Highlights\n\n* Shipped the prototype\n\n## Lowlights\n\n* Too many meetings\n",
}


def main(dest=DEFAULT):
    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    for rel, text in FILES.items():
        p = dest / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    (dest / "Journal.md").write_text(journal())
    (dest / "attachments").mkdir(parents=True, exist_ok=True)
    (dest / "attachments" / "diagram.png").write_bytes(png())
    print(f"sample workspace: {dest} ({sum(1 for _ in dest.rglob('*.md'))} notes)")
    return dest


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
