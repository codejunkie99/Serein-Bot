# Swarm board layout decision

The demo `swarm-board.html` shows three layouts of the same swarm (12 bots, nested helpers, 7 posts).
Use the buttons at the top, or open it with `?v=a`, `?v=b` or `?v=c`.

- A. Tree and feed. The start tree is on the left, indented by who started whom, with each bot's
  state dot and app. The messages are on the right in `#seq` order. The composer at the bottom
  speaks to the bot selected in the tree.
- B. One column. The bots are a strip of pills above the feed.
- C. State columns. The bots are sorted into working, waiting, stalled and done.

## Chosen: A

- It is the only layout that shows all three things the owner asked for at once: the message
  order, each bot's state, and the start tree.
- B loses the tree. With 12 or more bots the pill strip wraps into rows, and you cannot tell a
  helper from a worker.
- C loses the message order, so the board stops being a record. It also hides who started whom.
- In A, selecting a bot in the tree is the same act as choosing who the composer talks to, so
  commanding any bot needs no extra control.

The SwiftUI board (`Sources/Serein/SwarmBoardView.swift`) follows A. It closes with × at the top
right, uses 16 padding and 12 gaps, and every row and button can be pressed.
