#!/usr/bin/env python3
"""Fail when Serein's tool host reads a turn global instead of the calling turn's frame.

Two turns may run at once, so a tool call reads its own turn through `frame` (TurnFrame.swift),
resolved from the thread its call came from. The globals on RelayOrchestrator hold whichever
turn ran last. This script checks every `RelayToolHost` body and extension for `relay.<global>`.
It also counts where frames start and end, so a turn path that gains or loses one shows in
review: each start is matched by the run's end (`ended`) and by every way the start can fail.
The frame rules themselves are checked by `--verify-assistant-core` (suite turnFrame).
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


GLOBALS = ("turnThread", "startedByPerson", "admissionTurn", "runsUnattended", "typedWords", "personWords", "turnReadOutside")
READ = re.compile(r"\brelay\??\.(" + "|".join(GLOBALS) + r")\b")
HOST = re.compile(r"^(?:@MainActor )?(?:final class|extension) RelayToolHost\b")
LIFE = {"begin": re.compile(r"\bframes\.begin\("), "end": re.compile(r"\bframes\.end\(")}
# file: frame starts and ends. Change a number only with the reason in the commit.
WIRING = {"Sources/Serein/RelayOrchestrator.swift": {"begin": 2, "end": 4}}


def host_lines(text):
    """(line number, line) for each line inside a RelayToolHost body or extension. A body ends at
    the first `}` in column 0, as every top-level declaration here does."""
    inside = False
    for number, line in enumerate(text.splitlines(), 1):
        if HOST.match(line):
            inside = True
        elif inside and line.rstrip() == "}":
            inside = False
        elif inside:
            yield number, line


def problems(path, text):
    """What `path` breaks, as lines of text. `text` has its comments blanked."""
    found = [f"{path}:{number}: reads relay.{hit} in the tool host; read frame instead"
             for number, line in host_lines(text) for hit in READ.findall(line)]
    now = {name: count for name, pattern in LIFE.items() if (count := len(pattern.findall(text)))}
    if now != WIRING.get(path, {}):
        found.append(f"{path}: frame starts and ends are now {now}, the list says {WIRING.get(path, {})}")
    return found


def self_check():
    samples = {
        "extension RelayToolHost {\n  func f() { _ = frame.thread }\n}\n": 0,
        "extension RelayToolHost {\n  func f() { _ = relay.turnThread }\n}\n": 1,
        "extension RelayToolHost {\n  func f() { _ = relay.startedByPerson && relay.runsUnattended }\n}\n": 2,
        "extension RelayToolHost {\n  // relay.turnThread\n}\n": 0,
        "extension RelayToolHost {\n}\nextension RelayOrchestrator {\n  var x: String { relay.turnThread }\n}\n": 0,
        "@MainActor final class RelayToolHost {\n  func f() { _ = relay.admissionTurn }\n}\n": 1,
        "extension RelayToolHost {\n  func f() { _ = relay.turnThreadName }\n}\n": 0,
        "frames.begin(frameNow(thread: chat))\n": 1,
    }
    bad = [f"{sample!r} gave {got}" for sample, want in samples.items()
           if len(got := problems("Sample.swift", strip_comments(sample))) != want]
    if bad:
        raise SystemExit("turn-frame self-check failed:\n" + "\n".join(bad))


def main():
    self_check()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = []
    hosts = 0
    seen = set()
    for path in swift_files(root):
        seen.add(path)
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            text = strip_comments(handle.read())
        hosts += sum(1 for line in text.splitlines() if HOST.match(line))
        found += problems(path, text)
    found += [f"{path}: on the list, but the file is gone" for path in sorted(set(WIRING) - seen)]
    if not hosts:
        found.append("no RelayToolHost declaration found: the check reads nothing")
    if found:
        print("\n".join(found))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
