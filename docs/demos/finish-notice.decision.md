# Finish notice: layout decision

Demo: `docs/demos/finish-notice.html` (keys 1, 2, 3 or `?v=a|b|c`).

## Chosen: layout 1, "Header line"

```
[face] Writer finished              2:37 PM  ×
Draft the launch email for the beta list and
send me the draft before you send it to…
Wrote a 140-word draft with three subject…
Main chat · 6 min
[ Reply to Writer                  ] [ Open ]
```

Why:

- It reads like the notice it copies. The first line says who finished and when, the same job as "Session finished" in the reference. The person learns "Writer is done" before reading anything else.
- The title gets the full width for its two lines. In layout 2 the face column takes 40 points from every line, so a long title truncates sooner.
- × and the time sit on the header line, so they never collide with a wrapping title.
- A failure changes one word in one place ("Writer couldn't finish", in the danger colour) instead of a badge.
- Open is quiet (outlined) because the reply field is the new, main action. In layout 2 a solid Open pulls the eye away from the field.

Not chosen:

- Layout 2, "Face column": clean, but the bold title plus the face column gives two heavy things side by side, and the name moves to the meta line where it is easy to miss.
- Layout 3, "Compact, reply on hover": smallest, but the reply field is hidden until hover. That breaks the ask that everything is visible and keyboard reachable, and the one-line title truncates the long case badly.

## Sizes

Card 340 wide, radius 14 (`AssistantMetrics.bannerRadius`), padding 16, 12 between rows, 8 between cards. Face 20. Name 13 medium, title 13, summary 12 secondary, meta 12 faint, time 12 mono faint. Reply field and Open 32 high.

## For the cofounder: views to restyle

All in `Sources/Serein/FinishNoticePanel.swift`. Restyle freely; the behaviour lives elsewhere.

- `FinishNoticeView`: one card (header line, title, summary, meta line, reply field and Open).
- `FinishNoticeStackView`: the cards, newest on top, and the "N more finished" line.
- `FinishNoticeCenter.makePanel`: the floating panel at the top right of the pointer's screen.

What decides which finish shows a notice, where a reply goes, and how cards stack and fade is in `Sources/SereinCore/FinishNotice.swift`, checked by `AssistantCoreChecks+FinishNotice.swift`. Previews: `--ui-preview serein --ui-finish-notice short|long|swarm|stack [typed] --ui-capture /abs/path.png`.
