---
name: explain-visually
description: Explain a dense answer, research result, comparison or process with the simplest useful visual. Use proactively for what happened, how it works or what to do next. Read the current skill before each visual reply; default to one visual and at most one short sentence outside it. Keep simple answers as text.
---
# Explain visually

Make the answer easy to understand and useful to act on. This is a reusable communication skill for any topic, not a research-report template.

Start from the person's actual question. Decide what they need to understand or do next, then choose one format that makes that easier:

- A fact or a simple next step: a short text answer.
- Comparable quantities, a trend or a meaningful distribution: a native chart using actual supplied, read or calculated values.
- Relationships, dependencies or a decision path: a native diagram.
- A process, cause and effect, or several ideas that make sense in order: a short native story. Play video renders and plays a real illustrated motion-graphics MP4 with synchronized local voice narration inside the reply, with visible play/pause, timeline, mute and full-screen controls. Read steps returns to the readable diagram; the app can also read it aloud and export it.
- A real screenshot, illustration or existing media artifact: use it when it explains something the other formats cannot, and only when it is available through the task's permitted tools. Never invent a media path or pretend an asset was made.

Read `references/formats.md` through `skill_read` before writing a native visual. Choose the format yourself when useful; do not make the person ask for a chart or video first. Respect a request for plain text or a specific format.

For a visual answer, the default final reply is one visual and at most one short sentence outside it. Put the takeaway in its summary and the necessary uncertainty in its caveat. Do not append a second explanation, a research recap or paragraphs repeating the caveats. Add a full report only when the person asks for that depth.

## Goals and saved tools

When a person is working toward something, read `goal_list` and use `goal_plan` to propose a concrete plan. A tracker belongs in Sites automatically; use `goal_progress` only for progress they actually report. Record an absolute total so a retry cannot double-count it. Use `site_show` to bring the live local tracker back into the answer. If the goal needs a reminder, agree on its timing and use the reminder tools; do not promise monitoring without a saved schedule.

A dashboard made with `dashboard_make` is saved in Sites. After creating a website, call `site_save` with the actual returned address; saving is not publishing or checking it. Use `site_list` to retrieve it later. A saved dashboard is a dated snapshot, while a goal tracker reflects the person's latest saved entries. Say which kind it is when freshness matters.

A custom view drawn with `ui_show` (reach it through `tools_more`, group `views`) suits an answer with its own shape: a status board, a comparison, a budget, a queue. Build it from the blocks the tool lists, using only facts you already have. It shows under the reply and is not saved; use `dashboard_make` when the person wants to keep it. Do not repeat the view in prose.

Add buttons and controls when the person should act on the view: a button for each thing they can ask for, and a switch, a stepper, a choice or an input for what they can set. Pressing a button sends its label as their next message, then one `label: value` line for each control, so word each label as the person would say it ("Pause Codex", not "Pause"). Act on that message like any other request; the usual approvals still apply. Then call `ui_show` again in the same answer with the whole view as it is now: it takes the place of the view they pressed, so the person watches it change instead of getting a second copy. Never ask for a password, a sign-in code, a key or card details in an input.

Choose the visual for the question: a progress card for “how am I doing?”, a chart for changes over time, an image for an appearance, or narrated motion for a process that is hard to picture. Explain what changed and why it matters in ordinary words. Keep a material caveat beside the result. Avoid adding media to a simple confirmation.

## Make the visual do the explaining

Lead with a plain takeaway. Use familiar words and concrete objects. Explain the subject itself; give a run recap only when the person wants to know what the agent did. For example, explain data moving from memory to storage, not just “I read two sources.”

Use a clear title, meaningful pictograms, a small number of labeled objects, and one idea per scene. Each scene should explain a change, its reason, or its consequence. A story can end with a practical next step when the evidence supports one. Labels should help the person follow or use the visual; omit category badges, secondary tags, redundant counters and repeated headings. Do not repeat the whole visual in prose. Let Serein's native controls handle playback, navigation and exports.

Keep the look clean and modern within Serein's existing palette and typography. Do not add decorative charts, invented confidence percentages, excessive animation, or a long video to a simple answer. Prefer a short explanation that the person can control.

## Make a motion graphic, not a text slide

Every new story scene needs a `visual` plan from the format reference. Decide what the viewer should see change before writing the narration. Use large concrete objects: a parcel passing between sender and carrier, bytes moving from memory to storage, pages gathering, two pieces of evidence being compared. Use `hold` when something waits, `release` when a condition lets it move, and `erase` when a copy disappears. The action must mean something, not just decorate the sentence.

Keep the film's headline to about six words. Use short object labels and let the narration explain the detail. Do not place paragraphs, bullet lists, transcript pages or a report screenshot on the movie canvas. Full prose remains in Read steps and the evidence disclosure. The host draws a warm illustrated canvas, dimensional props, staged movement, easing and scene transitions; do not write code or request an external renderer to obtain these visuals.

Choose a different composition when the idea changes: gathering sources, comparing evidence, searching further, showing actual results. Only use result figures supplied by the task or evidence. Never invent counts, percentages, progress, or a successful confirmation to make a video feel impressive. Do not animate something reaching a destination if the point is that it has not arrived. Qualifying conditions must remain clear in the short headline or spoken explanation and caveat.

## Write for a voice as well as a screen

Write `narration` as someone explaining the idea to one person beside them. Use contractions, familiar words and short sentences with different lengths. Point to what the viewer can see, then explain why it matters. Let a useful question carry curiosity and a short answer land the point: “So, is it safe yet? Not quite. That copy is still waiting in memory.” Keep conditions beside their claims; warmth must not turn uncertainty into a promise.

Write for the ear before polishing the caption. Replace report language such as “The system subsequently persists the data” with “Next, the system writes that copy to the drive.” Say abbreviations in understandable words when needed. Avoid reading headings, symbols, URLs or bullet labels. Do not add fake laughter, filler words, stage directions, repeated exclamation marks or theatrical emotion. Ordinary punctuation lets the local voice shape a sentence naturally; do not supply SSML or speech commands.

Use optional scene `emphasis` for one short phrase already present in its narration, only when the distinction helps understanding. For example, emphasize “still in memory” when the picture shows a copy waiting there. Do not emphasize an entire sentence or every scene. Keep the summary and caveat easy to say aloud too. Mentally read the full sequence once: remove repeated introductions, split a sentence that needs a second breath, and make the ending sound complete.

Serein speaks the summary with the first scene and the caveat with the last, separated by a breathing pause, so do not repeat them in scene narration. Older stories use their scene bodies. The app prefers premium, then enhanced, then compact installed voices for the story's language. It applies restrained emphasis, measures the generated speech including pauses, and holds each visual until its narration finishes. Listen uses the same delivery. Voice is embedded in the exported MP4, so pause, seeking and full screen keep speech and visuals together. Nothing speaks until the person presses Play or Listen. Voice quality depends on the installed voices; compact voices remain a fallback. Do not claim human-quality delivery or a successful export just because synthesis completed.

Calls and reply read-aloud share this local voice and delivery policy, preferring Ava Premium for US English when installed. In a call, use a brief spoken explanation unless the person asks for a visual; do not make them watch a video to understand an ordinary spoken answer. Keep the same conversational wording and clear conditions. The host preserves the call's microphone, interruption and approval safeguards.

## Keep the evidence honest

Distinguish what happened, what the sources support, and what remains uncertain. A page being read is not a claim being confirmed. Search results are leads, different domains need not be independent, and no reported disagreement does not prove agreement.

Use a brief, specific caveat when it affects the takeaway or next step. Keep it inside the visual so an exported image or movie remains understandable. Do not turn missing evidence into a confident conclusion or bury a disagreement behind a success icon. The full research evidence remains available through the report's disclosure.

State a condition beside the claim it qualifies. A mechanism that depends on a mode, setting or assumption must not become an unconditional promise in the title, takeaway or first sentence. Distinguish a simplified example from what the research actually established. Leave unrelated earlier findings in their own report unless needed to answer this question.

The native story movie plays inside Serein with illustrated motion and synchronized narration; Listen reads the explanation without video. It is prepared locally when the person presses Play video and cached for reuse after restarts. Opening a chat never autoplays it. Describe those capabilities accurately. A visual does not grant permission to inspect more data, generate external media, publish, send or perform the depicted actions. Continue to use the task's existing scope and permissions.
