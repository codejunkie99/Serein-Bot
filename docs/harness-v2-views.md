# Handoff: harness v2 views

This note is for the cofounder who owns the SwiftUI views. The data layer is on branch
`feat/harness-v2`. No view code changed in it. Each item below names the view code at HEAD
(line numbers re-grepped in this repo after `c88202b7`), what changed under it, and the preview
that shows it. Line numbers differ from the paid repo's note, and items 8 and 13 hold facts only
this repo has.

## Preview seeds

`--ui-preview … --ui-harness-v2 [seed]` seeds Serein's chat (`previewHarnessV2`,
`Sources/Serein/PreviewSeeds+HarnessV2.swift`). It implies the `--ui-assistants` roster (Serein,
Scout, Planner, Writer) and adds Coach. With no seed, every seed is shown in order.

- `mention`: the person tags Writer (`mentions` on the "you" bubble). Writer's reply has
  `id` `handoff-report-…`, `from` Writer and `re` the bubble.
- `channel`: Serein's `channel-say-…` post to Scout, Serein's `handoff-post-…` to Planner, a
  `room-note-…` from Planner, and both reports. Scout's report carries `parts` (decisions,
  files and open).
- `side`: a side answer (`notice` false) to a busy chat, a `side-wait-…` line, and a turn moved
  to the background. That turn keeps its stopped partial reply, then gets a `background-…` line
  and its answer.
- `swarm`: the `swarm-…` line (`Swarm.line`) and the one merged answer from the lead.
- `refusal`: a person's tag of two assistants. Scout answers and Planner's refusal line sits
  under the person's message.
- `receipts`: the Allow all receipt and a `setting_change` receipt (approval level to Only risky
  steps), both through the real `deliver(receipt:into:)`, so Undo works in the preview.
- `archived`: Coach archived through the real `deletePlan` and `applyDelete`, with its receipt.

The seeds make no hand-off rows, so nothing starts a run. Previews write only to their throwaway
library and keep GateSettings in memory.

## View changes

| # | Item | Where (HEAD) | What changed under it | Seed |
|---|---|---|---|---|
| 1 | Hand-off rows and result card duplicate the report | `HandoffRows.swift:15`, `:19`, `:22`, `:94`, `:111`; `RelayTeams.swift:663` (`handoffsHere`) | Every report now posts once in the origin chat as the reporter's message (`handoff-report-<id>`, `RelayChannel.swift:40`). `HandoffResultCard` and the `record.reported` status rows show it a second time. Drop them or keep only the failed state. | `mention`, `channel` |
| 2 | QuickBarFace opens seat threads | `QuickBarFace.swift:34` to `:36` | `record.threadID` is now a hidden seat thread (`RelayTeams.swift:305`), an engine session only. Open `record.askedIn` (the origin chat) instead. | No seed: needs a running row. `--ui-team-chat handoff` starts one. |
| 3 | RelayPanel busy helpers | `RelayPanel.swift:1636`, `:1637`, `:1819` | `askedIn` is the origin chat, and a running row's seat is hidden. The list still works, but "open its chat" must go to the origin chat, not `threadID`. | No seed: `--ui-team-chat handoff`. |
| 4 | AssistantBoard owner of a seat thread | `AssistantBoard.swift:23`, `:27` | `assistantOwning(thread:)` maps a seat thread to `record.to`. Seat threads are never shown, so any view that lists chats by owner must skip `desk.hiddenThreads`. | No seed: `--ui-team-chat handoff`. |
| 5 | Messages render `re`, `mentions` and `parts` | `RelayPanel.swift:3419` to `:3428` (`replyRow`), `ChatParts.swift:489` to `:497` (`above`); fields at `Agent.swift:46` to `:58` | Draw the reply link (`re` is the id of the message answered), mention chips (`mentions`, on the "you" bubble and on posts) and the report's `parts` (decisions, files, open). Serein's own posts now carry `from` = Serein's id, so a `from` bubble can be Serein's. | `mention`, `channel`, `refusal` |
| 6 | The dead pair chat | Not in this repo ("Close Chat" occurs nowhere, and "⇄" only names Serein full ⇄ beside) | Nothing feeds a private chat between two assistants now. Every bot-to-bot message posts in the origin chat. Remove the pair chat view from the newer view code. | `channel` shows where those messages go now. |
| 7 | NewTeamSheet "Describe it" regressed | `NewTeamSheet.swift:10`, `:248`, `:258` to `:260` (waits for `proposal != nil`), `:69`, `:285` | `team_propose` is gone (replaced by `team_make`, which asks nothing), so no tool sets `Approval.proposal`. "Describe it" waits forever and then shows its failure. Import file (`:650`, `:651`) still builds a `TeamProposalDraft` and works. "Describe it" needs a new flow, for example sending the description as a chat message so the lead makes the team. | No seed: a sheet flow. |
| 8 | QueuedBubbles and "Send now" mostly dead | `ChatParts.swift:623`, `:695`, `:774`; `RelayPanel.swift:1816`, `:1817`, `:2229`, `:2414`; `SereinTasks.swift:635`, `:637` | A plain message to a busy chat takes a side seat at once (`RelaySideSeats.swift:22`) and never queues. Only attachments, a page, a trail, ⌥Return and paired-app requests still fill `pending`. This repo only: QueuedBubbles draws a run's steering lines from `run.steering.waiting` and always labels them sent (`ChatParts.swift:661`, `:664`). It has no "Waiting for the next reply" state, so do not copy that label from the paid view. | `side` |
| 9 | New line ids | `side-wait-` `RelaySideSeats.swift:32`; `background-` `:69`; `swarm-` `RelaySwarm.swift:51`; `channel-say-` `RelayGroupTurn.swift:78`; `handoff-post-` `RelayChannel.swift:11`; `handoff-report-` `SereinCore/HandoffPacket.swift:260`; `room-note-` `RelayChannel.swift:82` | These lines have `from` set, and `HostLineView` (`ChatParts.swift:429`, the `from` check at `:439`) draws any line with `from` as a warning banner. The side-wait, background and refusal lines are not warnings. Draw them as plain lines under the message they answer (`re`). The `swarm_start` step reads "Asked several models at once" (`SereinCore/WebTasks.swift:350`). | `side`, `swarm`, `refusal`, `channel` |
| 10 | No archived-assistant roster UI | `RelayAssistantTools.swift:825` (archive at Allow all); `RelayRooms.swift:320` passes `archived: []` | At Allow all, a delete archives: the assistant leaves the roster, its files wait in `relay/removed`, and the receipt's Undo brings it back while the roster history holds the change. No view lists archived assistants or brings one back outside the receipt. | `archived` |
| 11 | No `settingChanges` history | `SereinCore/ChatSettings.swift:126` (`SettingsLedger`), `RelaySettingChange.swift:41` | Each change from the chat lands in `relay.settingsLedger.open` (at most 50) with its Undo. The ledger is in memory only, so after a relaunch Undo reads as gone. No view lists the changes. | `receipts` |
| 12 | AskBefore comment names `team_propose` | `AskBefore.swift:586`; the card at `:401` to `:403`, `:589`; `DecisionDock.swift:27` | The comment and `TeamProposalCard` describe the `team_propose` card, which no tool raises now. Only Import file and Change… still use the card. | No seed: comment only. |
| 13 | Level names are this repo's own | `SereinCore/ApprovalLevel.swift:41` to `:43`; the dial at `AskBefore.swift:4`, `:19` | This repo names the levels Every step, Only risky steps and Allow all, not the paid repo's Manual and Auto. `approval_level`, its errors and the `setting_change` receipt use these words, so the `receipts` seed reads "How much Serein asks" from Allow all to Only risky steps. Keep these words when porting any paid view text. | `receipts` |
