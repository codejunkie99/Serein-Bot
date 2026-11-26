#!/usr/bin/env python3
"""Fail when swarm prompt text lives outside Sources/SereinCore/SwarmPrompts.swift.

The owner asked for one place for every word a bot reads about swarms and team calls, shared by
the free and paid apps (2026-11-26). Peers and PeerTools build those turns, so they are where old
copies would come back. Each phrase below is a piece of a prompt; it may appear only in
SwarmPrompts.swift. The phrases from before the move ("Swarm Goal:", the old verifier and tool
text) may not appear anywhere.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.join("Sources", "SereinCore", "SwarmPrompts.swift")

# Text that belongs to SwarmPrompts only.
OWNED = [
    "one worker in a swarm",
    "read-only verifier of a swarm",
    "Fix your slice",
    "The person who started this swarm says",
    "called by another agent",
    "Your caller does not answer questions here",
    "Created a swarm of",
    "Start a swarm.",
]

# Text from before the move. Gone for good.
GONE = [
    "Swarm Goal:",
    "You are the read-only verifier (round",
    "Revise your slice",
    "Run any number of parallel workers over a shared SwarmBoard",
]

SCANNED = [os.path.join("Sources", "SereinEngines"), os.path.join("Sources", "SereinCore")]


def main(argv):
    roots = argv[1:] or [os.path.join(ROOT, d) for d in SCANNED]
    home = os.path.join(ROOT, HOME)
    if not os.path.exists(home):
        print(f"FAIL: {HOME} is missing")
        return 1
    failures = []
    for top in roots:
        paths = [top] if os.path.isfile(top) else [
            os.path.join(d, f) for d, _, fs in os.walk(top) for f in fs if f.endswith(".swift")]
        for path in sorted(paths):
            if os.path.abspath(path) == home:
                continue
            with open(path, encoding="utf-8") as fh:
                for number, line in enumerate(fh, 1):
                    for phrase in OWNED + GONE:
                        if phrase in line:
                            failures.append(f"FAIL: {os.path.relpath(path, ROOT)}:{number} holds swarm prompt text {phrase!r}")
    with open(home, encoding="utf-8") as fh:
        text = fh.read()
    for phrase in OWNED:
        if phrase not in text:
            failures.append(f"FAIL: {HOME} lost {phrase!r}")
    for line in failures:
        print(line)
    if failures:
        return 1
    print("PASS: swarm prompts live only in SwarmPrompts.swift")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
