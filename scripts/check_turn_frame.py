#!/usr/bin/env python3
"""Fail when Serein's tool path reads a turn global instead of the calling turn's frame.

Two turns may run at once, so a tool call reads its own turn through `frame` (TurnFrame.swift),
the frame `RelayToolHost.call` bound for it. The globals on RelayOrchestrator hold whichever turn
ran last. The tool path is every `RelayToolHost` body and extension, every function that takes a
`frame: TurnFrame`, and `RelayPrompt.volatile`: none of them reads `relay.<global>`, and a function
handed a frame reads no global bare either. It also counts where frames start and end, so a turn
path that gains or loses one shows in review: each start is matched by the run's end (`ended`) and
by every way the start can fail. The frame rules themselves are checked by
`--verify-assistant-core` (suite turnFrame).
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


GLOBALS = ("turnThread", "startedByPerson", "admissionTurn", "runsUnattended", "typedWords", "personWords", "turnReadOutside",
           "working", "turnAuthority", "scheduledProfileID", "actingProfile", "checkingGoal", "checkingIn", "turnProfileID",
           "turnPage", "standing", "admission")
READ = re.compile(r"\brelay\??\.(" + "|".join(GLOBALS) + r")\b")
# Read bare (or through self) inside a function handed a frame. `standing` and `admission` are
# left out: the host's own `standing()` and the frame's `admission` already read the frame.
BARE = re.compile(r"(?:(?<![.\w])|\bself\.)(" + "|".join(g for g in GLOBALS if g not in ("standing", "admission")) + r")\b(?!\s*:)")
TAKES_FRAME = re.compile(r"\bfunc \w+[^{]*\bframe: TurnFrame\b")
VOLATILE = re.compile(r"\bstatic func volatile\(")
HOST = re.compile(r"^(?:@MainActor )?(?:final class|extension) RelayToolHost\b")
LIFE = {"begin": re.compile(r"\bframes\.begin\("), "end": re.compile(r"\bframes\.end\(")}
# file: frame starts and ends. Change a number only with the reason in the commit.
WIRING = {
    # turn() and the scheduled start, plus the DEBUG `turnPage` setter RelayChecks uses.
    "Sources/Serein/RelayOrchestrator.swift": {"begin": 3, "end": 4},
    # The turn-frame check opens two chats' turns on a real Relay and ends both.
    "Sources/Serein/AssistantCoreChecks+TurnFrame.swift": {"begin": 2, "end": 2},
    # The side-seat check opens the front turn in the seat's chat and ends it.
    "Sources/Serein/AssistantCoreChecks+GroupTurn.swift": {"begin": 1, "end": 1},
    # The bots-unbounded check opens a person's and a bot's turn on a real Relay and ends both.
    "Sources/Serein/AssistantCoreChecks+BotsUnbounded.swift": {"begin": 2, "end": 2},
    # The setting_change check opens a person's and an assistant's turn on a real Relay.
    "Sources/Serein/AssistantCoreChecks+SettingChange.swift": {"begin": 1},
    # The settings-undo machine starts, ends and late-ends turns on both chats.
    "Sources/SereinCore/Formal/SettingsMachine.swift": {"begin": 1, "end": 2},
}


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


def bodies(text, start):
    """(line number, line) for each line of every function whose header matches `start`, from the
    header to the brace that closes it."""
    lines = text.splitlines()
    for first, line in enumerate(lines):
        if not start.search(line):
            continue
        depth, opened = 0, False
        for number in range(first, len(lines)):
            depth += lines[number].count("{") - lines[number].count("}")
            opened = opened or "{" in lines[number]
            yield number + 1, lines[number]
            if opened and depth <= 0:
                break


def problems(path, text):
    """What `path` breaks, as lines of text. `text` has its comments blanked."""
    path_lines = dict(host_lines(text))
    path_lines.update(bodies(text, TAKES_FRAME))
    path_lines.update(bodies(text, VOLATILE))
    found = [f"{path}:{number}: reads relay.{hit} in the tool path; read frame instead"
             for number, line in sorted(path_lines.items()) for hit in READ.findall(line)]
    found += [f"{path}:{number}: reads {hit} in a function handed a frame; read frame.{hit} instead"
              for number, line in bodies(text, TAKES_FRAME) for hit in BARE.findall(line)]
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
        "extension RelayOrchestrator {\n  func f(frame: TurnFrame) {\n    g(personWords: frame.personWords)\n  }\n}\n": 0,
        "extension RelayToolHost {\n  func f() { _ = relay.working || relay.actingProfile == nil }\n}\n": 2,
        "extension RelayToolHost {\n  func f() { _ = relay.admission(.board); _ = relay.standing(present: true) }\n}\n": 2,
        "extension RelayToolHost {\n  func f() { _ = standing(); _ = frame.admission(.board) }\n}\n": 0,
        "extension RelayOrchestrator {\n  func f(_ x: Int, frame: TurnFrame) -> Int {\n    _ = turnThread\n    return 0\n  }\n}\n": 1,
        "extension RelayOrchestrator {\n  func f(frame: TurnFrame) {\n    _ = self.turnProfileID + frame.typedWords\n  }\n}\n": 1,
        "extension RelayOrchestrator {\n  func f(frame: TurnFrame) {\n    _ = frame.typedWords + frame.profile\n  }\n  var g: String { turnThread }\n}\n": 0,
        "enum RelayPrompt {\n  static func volatile(request: String, thread: String?) -> String {\n    relay?.turnPage?.line ?? \"\"\n  }\n}\n": 1,
        "enum RelayPrompt {\n  static func stable() -> String { relay?.turnPage?.line ?? \"\" }\n}\n": 0,
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
