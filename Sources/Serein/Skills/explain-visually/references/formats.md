# Native visual formats

Write one closed fenced block in the assistant's reply. These are bounded data formats, not HTML, JavaScript or Mermaid. The app draws them natively. An invalid or unfinished block remains code, so check the shape and bounds before sending it.

## Playable story

Use the fence language `story`, containing one JSON object:

```json
{
  "title": "A write still has to reach storage",
  "summary": "Bytes can be visible to an app while they are still only in memory.",
  "nodes": ["App", "Memory", "Drive"],
  "icons": ["app", "memory", "disk"],
  "scenes": [
    {"title": "The app writes", "body": "The system may first keep the bytes in memory. The app can see them, but a power cut can erase that temporary copy.", "focus": 1, "visual": {"kind": "transfer", "from": 0, "to": 1, "headline": "Visible does not mean permanent"}, "narration": "The bytes first wait in the computer’s memory. They look saved, but this temporary copy disappears if the power goes out."},
    {"title": "A flush asks for a durable copy", "body": "The system asks the drive to finish saving. This relies on the operating system and the drive honoring the request.", "focus": 2, "visual": {"kind": "release", "from": 1, "to": 2, "headline": "If the system honors the flush"}},
    {"title": "Check what the guarantee covers", "body": "Distinguish a completed write from a completed flush. A real durability claim also needs the system's documented conditions and relevant test evidence.", "focus": 2, "visual": {"kind": "focus", "headline": "Check what the promise covers"}}
  ],
  "caveat": "This explains the mechanism; it is not an independent test of a particular drive."
}
```

- `title`: nonempty, at most 100 characters. `summary`: nonempty, at most 300.
- `nodes`: 2–4 distinct labels, each at most 32 characters, arranged in the visual's meaningful order.
- `icons`: optional; if present, one per node. Allowed values: `page`, `search`, `compare`, `result`, `app`, `memory`, `disk`, `person`, `clock`, `warning`, `parcel`, `truck`, `cloud`, `energy`.
- `scenes`: 2–5. Each has a nonempty `title` of at most 72 characters, nonempty `body` of at most 300, and integer `focus` naming a zero-based node index. Prefer much shorter captions when they explain the idea fully.
- Scene `narration`: optional plain spoken text, nonempty and at most 500 characters. Use conversational wording instead of reading diagram labels aloud. If omitted, the scene body is spoken. The summary and caveat are included automatically; the speech cannot omit them.
- Scene `emphasis`: optional exact phrase from that scene's `narration` (or `body` if narration is absent), nonempty and at most 60 characters. Prefer two or three words that carry the important distinction, for example `"emphasis": "still in memory"`. The host applies moderate spoken emphasis, not a caption or a new claim. Omit it where ordinary delivery is enough. All text remains plain text; never insert SSML, stage directions or pronunciation commands.
- Scene `visual`: include it for every new motion graphic. Its `kind` is one of `gather` (documents arrive), `compare` (two sources meet a lens), `search` (a lens explores pages), `result` (actual outcome counts), `transfer` (objects move), `hold` (objects wait at a barrier), `release` (the barrier opens), `erase` (a copy dissolves), or `focus` (introduce one concrete object).
- Visual `headline`: optional, at most 64 characters; aim for six words. This replaces paragraph text on the movie canvas. Scene bodies remain readable through Read steps and are spoken when no narration is supplied.
- `transfer`, `hold` and `release` require distinct `from` and `to` node indices. Other kinds use the scene's `focus`. Choose only actions supported by the explanation, with conditions stated explicitly.
- Visual `figures`: optional 1–3 objects of `{ "label": "Unconfirmed", "value": 3 }`. Labels are unique, nonempty and at most 24 characters; values are integers from 0 to 1,000,000. `result` displays these as actual counts, never percentages. `gather` can use the first figure as its real page count. Do not invent these values. Other compositions do not display figures.
- `caveat`: nonempty, at most 350 characters; aim for one short sentence. If no factual uncertainty applies, state the example's scope or assumptions without inventing a warning.
- Whole JSON: at most 12,000 UTF-8 bytes. All words are plain text. No scripts, remote assets, credentials or hidden data.

Play video prepares a local 1920 × 1080 illustrated motion-graphics MP4 at 30 fps with embedded voice narration. The warm canvas uses large props, short headlines and actual animated actions, not paragraph slides. Each scene lasts for its measured speech plus a brief pause; a long sentence is never cut off to fit a fixed timer. Controls include play/pause, timeline, mute and full screen. Read steps shows the diagram and scene captions; people can select an object or listen. Cached narrated videos reopen paused after a restart. Older silent or text-slide caches are regenerated in the new illustrated style on Play. Image export saves the selected scene. Video export includes the same synchronized audio. Do not claim an export has been saved until it has actually been created.

## Chart

Use fence language `chart` with JSON:

```json
{"kind":"bar","title":"Tasks finished","labels":["Monday","Tuesday","Wednesday"],"series":[{"name":"Tasks","values":[4,7,5]}],"unit":"tasks"}
```

Kinds: `bar`, `line`, `pie`. Title, series name and unit are optional. Each series has one finite number per label. Labels and series names are unique. At most 200 values total; a pie has one series, 1–6 nonnegative slices and a positive total. Text fields are at most 80 characters. Use a pie only for meaningful parts of a whole. The example's values are illustrative, not research evidence.

## Diagram

Use fence language `diagram`. An optional `title:` line is followed by one arrow per line:

```text
title: Where the work waits
Request -> Queue: waits for capacity
Queue -> Worker: starts when ready
Worker -> Result: returns the outcome
```

The arrow label after `:` is optional. At most 40 nodes and 200 arrows; node names, labels and title are at most 80 characters. This is Serein's small grammar, not Mermaid. Choose a readable small diagram rather than filling the limits.
