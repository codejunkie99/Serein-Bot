#!/usr/bin/env python3
"""Fail when a staffing path can show a card or ask the person.

The owner chose autonomous staffing (2026-11-25): an assistant seats, makes or saves a team with
no card, and a refusal is a sentence the model follows. `Staffing.decide` has no ask verdict, so
the type holds the core; this script holds the shell. The bodies of the tools that staff
(assistant_handoff, assistant_make, team_make) and of `RelayOrchestrator.staff` may not call a
card or an admission ask, and the removed card paths may not come back. The behavior is checked
by `--verify-assistant-core` (suite staffing).
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


# file: functions that staff, by the text that opens them.
STAFFING = {
    "Sources/Serein/RelayTeams.swift": ["func handOff(", "func makeTeam("],
    "Sources/Serein/RelayAssistantTools.swift": ["func makeAssistant(_ a:"],
    "Sources/Serein/RelayRooms.swift": ["func staff("],
}
CARD = re.compile(r"\b(confirmAnswer|confirm|gateTeam|askPerson|Admission\.decide|TypedConsent)\b|\.ask\b")
GONE = re.compile(r"\b(team_propose|proposeTeam|gateTeam|MakeProposals|foldIntoTargetChat|showProposalCard|answerProposal)\b")


def body(text, opener):
    """The text of the function `opener` starts, through its closing brace, or None."""
    start = text.find(opener)
    if start < 0:
        return None
    depth, i = 0, text.index("{", start)
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[start:j + 1]
    return None


def problems(path, text):
    """What `path` breaks, as lines of text. `text` has its comments blanked."""
    found = [f"{path}:{n}: a removed card path is back ({m.group(1)})"
             for n, line in enumerate(text.splitlines(), 1) for m in [GONE.search(line)] if m]
    for opener in STAFFING.get(path, []):
        got = body(text, opener)
        if got is None:
            found.append(f"{path}: `{opener}` is gone; update STAFFING")
        elif (hit := CARD.search(got)):
            found.append(f"{path}: `{opener}` calls {hit.group(0)}; staffing never shows a card")
    return found


def self_check():
    teams = "Sources/Serein/RelayTeams.swift"
    clean = "func handOff(a) {\n  if x { y() }\n}\nfunc makeTeam(a) { z() }\n"
    samples = {
        (teams, clean): 0,
        (teams, clean.replace("y()", "await relay.confirmAnswer(t)")): 1,
        (teams, clean.replace("z()", "gateTeam(.settings)")): 2,
        (teams, clean + "func other() { confirmAnswer() }\n"): 0,
        (teams, "func handOff(a) { }\n"): 1,
        ("Sources/SereinCore/Relay.swift", 'tool("team_propose")\n'): 1,
        ("Sources/SereinCore/Relay.swift", 'tool("team_make")\n'): 0,
    }
    bad = [f"{sample!r} gave {got}" for sample, want in samples.items()
           if len(got := problems(sample[0], strip_comments(sample[1]))) != want]
    if bad:
        raise SystemExit("staffing-no-card self-check failed:\n" + "\n".join(bad))


def main():
    self_check()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found, seen = [], set()
    for path in swift_files(root):
        # Views are the cofounder's; the sheet's Describe it still names the old tool in words.
        if not path.startswith("Sources/") or path.endswith(("NewTeamSheet.swift", "AskBefore.swift")):
            continue
        seen.add(path)
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            found += problems(path, strip_comments(handle.read()))
    found += [f"{path}: on the list, but the file is gone" for path in sorted(set(STAFFING) - seen)]
    if found:
        print("\n".join(found))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
