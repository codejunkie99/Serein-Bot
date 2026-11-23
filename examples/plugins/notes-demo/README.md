# Notes demo plugin

A complete Serein plugin in two files, to copy when you write your own.

- `serein-plugin.json`: who it is, how to start its MCP server, each tool with its risk (`read`, `write`, `send`, `delete`, `pay`), and what it may reach.
- `server.py`: a stdio MCP server using only Python's standard library.
- `skills/daily-review/SKILL.md`: a skill, plain instructions Serein reads.

Try it: Serein › Settings › Plugins › Add plugin…, choose this folder, then turn it on. Ask Serein "add a note: buy milk", then "what are my notes?". Clearing the notes always asks first, because `clear_notes` is a `delete` tool.
