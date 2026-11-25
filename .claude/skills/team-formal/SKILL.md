---
name: team-formal
description: Model-checks Serein's team reducers by exploring every order of steps. Covers hand-off chains, report delivery, staffing and reach, and hand-off packets. Use when a change touches HandoffLedger or AssistantHandoff in AssistantTeams.swift, Staffing.swift, Workroom.swift, Reach, RelayTeam.making or RelayTeam.undoing, HandoffPacket.swift, or the hand-off glue in Sources/Serein/RelayTeams.swift (closeHandoff, launch, finishHandoff, deliverChainResults, deliverHandoffReports, sweepHandoffs, stopHandoffs, startWaitingHandoffs). Also use when you add a team machine, such as Frames or SettingsUndo.
---

# Team formal checks

Each check is a bounded model checker written in Swift. It starts from an empty world and runs every step the shell can take, in every order, up to small caps. It runs the shipped reducers at each step. It checks each property on every state it reaches. When a property breaks, it prints the shortest path to the break.

**The properties.**
- **Chain.** No assistant holds one task twice. A task has at most `HandoffLedger.maxChain` holders. A root has at most `maxPerRoot` rows. A parent closes only after its children. One hand-off holds a chat at a time. Stop Everything leaves nothing running. A closed hand-off never opens again. Every admitted row can still end.
- **Report.** A report is claimed only once sealed (closed), and at most once. No reader turn starts before the claim. Each report is shown at most once, including after a relaunch, a sweep, or a replayed delivery of any id. A wake turn runs once per report. Each report is posted into the origin chat at most once, and no wake turn starts before its post is there, even when a busy chat holds the post and a relaunch loses it.
- **Staffing.** A seat's reach is within its parent's reach, and the parent's reach is within the ceiling, at every step and after `renarrow`. The roster has at most 16 profiles. A root makes at most `Staffing.makesPerRoot` assistants. An archived assistant is never seated. Undo of a make restores the roster exactly.
- **Packet.** A packet is sent only after it is built and sealed. The personal mark is never dropped, not in `withheld()` and not in `markdown()`. A sealed file is never written again.

**The harm.** A broken chain rule lets a task loop between assistants or run without a cap. A broken claim shows one result twice or never. A broken reach lets a made assistant reach past what the person allowed. A dropped personal mark sends private words to another assistant.

## Run it

```bash
bash scripts/check_formal.sh
```

The script runs `swift build --product Serein` and then `.build/debug/Serein --verify-formal`. It prints one line per machine: PASS or FAIL, states, transitions, depth, seconds, and bounds. On a break it prints the property and the shortest counterexample, and exits 1. A build failure exits 2. To run some machines only, name them: `bash scripts/check_formal.sh chain report`. The names are `chain`, `chain-caps`, `report`, `staffing`, and `packet`.

## What it covers

| Machine | Check file | Code it runs |
|---|---|---|
| chain, chain-caps | `Sources/SereinCore/Formal/ChainMachine.swift`, `HandoffWorld.swift` | `HandoffLedger.admit`, `chainRefusal`, `refusal`, `running(thread:)`, `closable`, `expire`, `stop`, `claimReport` in `Sources/SereinCore/AssistantTeams.swift` |
| report | `Sources/SereinCore/Formal/ReportMachine.swift`, `HandoffWorld.swift` | the same reducers, with replays of any id and report posts that a busy chat holds (`postReport`, `channelPost` in `Sources/Serein/RelayChannel.swift`) |
| staffing | `Sources/SereinCore/Formal/StaffingMachine.swift` | `Staffing.decide` (`Staffing.swift`), `Workroom.renarrow`, `recordMade`, `Reach.narrowed`, `Reach.person` (`Workroom.swift`), `RelayTeam.making` (`AssistantLifecycle.swift`), `RelayTeam.undoing` (`AssistantTeams.swift`) |
| packet | `Sources/SereinCore/Formal/PacketMachine.swift` | `HandoffPacket.init`, `withheld()`, `markdown()`, `withheldWords` (`HandoffPacket.swift`) |

The checker itself is `Sources/SereinCore/Formal/FormalChecker.swift`. The flag is one line in `Sources/Serein/main.swift`, next to `--verify-assistant-core`.

**Mirrored, not called.** The shell glue in `Sources/Serein/RelayTeams.swift` is on the main actor in the app target, so SereinCore cannot call it. `HandoffWorld` copies each of those functions as one step. When you change one of them, change its copy in `HandoffWorld.swift` in the same commit. The staffing machine copies how the shell applies a verdict. The packet machine copies the writer and the sender, and it models the seal as a write-once map. These are copies because the shell parts of TEAMS-V2 commits 4 and 6 are not built yet. Replace each copy with the real call when that code lands in SereinCore.

**Shortcuts.** Waiting hand-offs start right after every step (`startingWaiting`), so the wait of up to 15 seconds for the next sweep is not explored. Stop Everything and a close with its cascade are each one step. A wake turn's post and its claim are two steps, so a relaunch can fall between them.

**Bounds.** The bounds are printed on each line. Chain uses 4 assistants, 1 root, 4 rows, 1 relaunch, and 1 day. Chain-caps uses 5 assistants and 9 rows, with sends and starts only. With 5 the holder cap binds before the no-repeat rule. With 4, the open limit of 3 per assistant stops the rows at 8, so the per-root cap is never reached. Report uses 3 assistants and 3 rows, with replays. Staffing uses 15 profiles, 4 seats, and 2 makes. Packet uses 3 packets. A cap that the bounds never reach passes even when the cap is broken, so break each cap once when you change the bounds. Keep the whole gate under a minute. A machine that explores past 1,500,000 states fails and tells you to lower the bounds.

## Real bug or model bug

Read the counterexample step by step against the shipped code. Each step label names one shell function.
- The steps can happen in the app, and the property is the rule in TEAMS-V2. Then it is a real bug. Fix the reducer.
- A step cannot happen in the app, for example a send from a chat with no live run. Then the model is wrong. Fix the step in the machine file.
- The rule changed on purpose. Then change the property and its name, and say why in the commit.

## Add a machine

Frames (TEAMS-V2 row 2a) and SettingsUndo (row 10) are not checked yet. To add one, write `Sources/SereinCore/Formal/<Name>Machine.swift` with a `static var machine: FormalMachine<World>`. Then add one line to `FormalCheck.machines` in `FormalChecker.swift`. Then add it to the coverage table here. Before you commit it, break its reducer once on purpose and confirm that the machine prints a counterexample.

## Sync

Last confirmed against the code of the commit that last changed this line (feat/harness-v2, "feat(relay): one channel in the origin chat"). When the covered code changes after that commit, rerun the check and read every step in the machine files against the new code. Move this commit forward only after you confirm that the machines still describe the code.
