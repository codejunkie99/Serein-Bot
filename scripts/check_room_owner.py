#!/usr/bin/env python3
"""Fail when code outside RelayRooms.swift reads or writes the room folders.

Rooms (Sources/Serein/RelayRooms.swift) is the only writer under relay/rooms/: it seals each
packet once, 0600 in 0700 folders, off the main actor, before the hand-off is marked launched.
A second writer would skip all four. This script flags `relay/rooms` and `RoomFiles.` anywhere
else, and pins the one launch that waits on the seal. The behavior is checked by
`--verify-assistant-core` (suite roomFiles).
"""
import os
import re
import sys


def strip_comments(text):
    """Blank // and /* */ comments. Newlines stay so a hit keeps its line number.
    Markers inside a string are left alone. Block comments nest, as they do in Swift.
    """
    out = []
    i = 0
    n = len(text)

    def copy_string(quote):
        nonlocal i
        out.append(text[i:i + len(quote)])
        i += len(quote)
        while i < n:
            if quote == '"' and text[i] == "\\":
                out.append(text[i])
                i += 1
                if i < n:
                    out.append(text[i])
                    i += 1
                continue
            if text.startswith(quote, i):
                out.append(text[i:i + len(quote)])
                i += len(quote)
                return
            out.append(text[i])
            i += 1

    while i < n:
        if text.startswith('"""', i):
            copy_string('"""')
            continue
        if text[i] == '"':
            copy_string('"')
            continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if text.startswith("/*", i):
            out.append(" ")
            out.append(" ")
            i += 2
            depth = 1
            while i < n and depth:
                if text[i] == "\n":
                    out.append("\n")
                    i += 1
                elif text.startswith("/*", i):
                    depth += 1
                    out.append(" ")
                    out.append(" ")
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    out.append(" ")
                    out.append(" ")
                    i += 2
                else:
                    out.append(" ")
                    i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)



def swift_files(root):
    """Every Swift file outside the top-level Tests/ directory.
    A nested directory named Tests is still scanned. The file is read in full so a split
    attribute is visible.
    """
    root = os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if not name.startswith(".")]
        if os.path.abspath(dirpath) == root:
            dirnames[:] = [name for name in dirnames if name != "Tests"]
        for name in filenames:
            if name.endswith(".swift"):
                yield os.path.relpath(os.path.join(dirpath, name), root)


OWNER = "Sources/Serein/RelayRooms.swift"
CHECKS = "Sources/Serein/AssistantCoreChecks+RoomFiles.swift"
TOUCH = re.compile(r'"relay/rooms|\bRoomFiles\.')
LAUNCH = re.compile(r"\brooms\.launch\(")
# file: launches that wait on the seal. Change a number only with the reason in the commit.
WIRING = {"Sources/Serein/RelayTeams.swift": 1}


def problems(path, text):
    """What `path` breaks, as lines of text. `text` has its comments blanked."""
    found = []
    if path not in (OWNER, CHECKS):
        found += [f"{path}:{number}: touches the room folders; go through Rooms in {OWNER}"
                  for number, line in enumerate(text.splitlines(), 1) if TOUCH.search(line)]
    launches = len(LAUNCH.findall(text))
    if launches != WIRING.get(path, 0):
        found.append(f"{path}: {launches} sealed launches, the list says {WIRING.get(path, 0)}")
    return found


def self_check():
    samples = {
        ("Sources/Serein/Other.swift", 'let a = "relay/rooms/x"\n'): 1,
        ("Sources/Serein/Other.swift", "try RoomFiles.write(t, to: u)\n"): 1,
        ("Sources/Serein/Other.swift", "// relay/rooms\n"): 0,
        ("Sources/Serein/Other.swift", "let roomFilesCount = 1\n"): 0,
        (OWNER, 'static let path = "relay/rooms"\n'): 0,
        ("Sources/Serein/Other.swift", "await rooms.launch(id, room: r)\n"): 1,
        ("Sources/Serein/RelayTeams.swift", "await rooms.launch(id, room: r)\n"): 0,
        ("Sources/Serein/RelayTeams.swift", "\n"): 1,
    }
    bad = [f"{sample!r} gave {got}" for sample, want in samples.items()
           if len(got := problems(sample[0], strip_comments(sample[1]))) != want]
    if bad:
        raise SystemExit("room-owner self-check failed:\n" + "\n".join(bad))


def main():
    self_check()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = []
    seen = set()
    for path in swift_files(root):
        seen.add(path)
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            found += problems(path, strip_comments(handle.read()))
    found += [f"{path}: on the list, but the file is gone" for path in sorted((set(WIRING) | {OWNER}) - seen)]
    if found:
        print("\n".join(found))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
