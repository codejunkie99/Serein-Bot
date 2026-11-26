# Build a Serein plugin

A plugin teaches Serein, the assistant, a new skill. It is a folder. You can write one in ten minutes, in any language.

The fastest start:

```sh
serein-agent plugin init "Weather"      # a working template: manifest, Python MCP server, skill
serein-agent plugin validate weather     # checks it as Serein will, server in the sandbox included
serein-agent plugin test weather weather_hello '{"who":"me"}'   # one call, as Serein makes it
```

Or copy [`examples/plugins/notes-demo`](../examples/plugins/notes-demo).

## 1. A skill: instructions only

Make a folder with `SKILL.md`:

```markdown
---
name: weekly-report
description: Write the user's weekly report when they ask for it on Fridays.
---

1. Ask Serein’s AI apps what changed this week in each project (agent_start, destination project).
2. Group the changes by project, three bullets each.
3. Show the draft and wait for the user's edits.
```

- `name` is lowercase words joined by hyphens.
- `description` says when to use the skill.
- The rest is the method.

Serein lists installed skills and reads one before doing its job. A skill grants no access. Serein ships one skill of its own, `design-your-look`, and a plugin cannot replace it. Put more skills in `skills/<name>/SKILL.md` inside the same folder, next to any reference files they mention.

## 2. Tools: a small MCP server

Add `serein-plugin.json` and a stdio [MCP](https://modelcontextprotocol.io) server:

```json
{
  "id": "dev.you.weather",
  "name": "Weather",
  "version": "1.0.0",
  "description": "Today's forecast.",
  "license": "MIT",
  "mcp": { "command": "/usr/bin/python3", "args": ["-I", "server.py"], "env": ["WEATHER_KEY"] },
  "tools": [{ "name": "forecast", "risk": "read" }],
  "permissions": { "network": ["api.weather.example"] }
}
```

- **`tools`** lists every tool your server offers, with its risk. Serein hides any tool you do not list.
  - `read`: looks something up.
  - `write`: creates or changes the user's data.
  - `send`: anything other people see.
  - `delete`: removes something.
  - `pay`: moves money.
  - With Settings › Assistants › Asks first set to Only risky steps, `read` and `write` tools run on their own; with Every step they ask. `send`, `delete` and `pay` always ask the user first.
- **`mcp.command`** is either a file in your folder (`./bin/server`) or a system interpreter with your script in `args`.
- **`env`** names the secrets your server needs. The user types them in Marketplace › Plugins, they are kept in the Keychain, and your server gets them as environment variables.
- **`permissions.network`** lists the hosts you call; leave it out for no network.
- **`permissions.files: "plugin-data"`** gives you a folder of your own, at `$SEREIN_PLUGIN_DATA`.

## What your server can and cannot do

Serein starts your server for each call, with your plugin folder as its working folder, inside a macOS sandbox:
- **Allowed:** it reads the system and its own folder, and writes its data folder and temporary files.
- **Not allowed:** the user's home folder, changes to its own installed files, and the network (unless the manifest lists hosts).
- **Network caveat:** macOS sandbox rules cannot name hosts. A plugin that lists any host gets outbound network. The hosts are shown to the user when they add the plugin.

Every call passes Serein’s policy, and agent history records it. If your tool's schema changes after the user turned the plugin on, calls are refused until they turn it on again (that is the review). Results reach the model as untrusted data.

## Try it

1. In Serein, open Marketplace › Plugins › Add Plugin › From a Folder…, choose your folder and read the review.
2. Turn the plugin on. Serein starts your server once and checks that it offers every tool you listed.
3. Press ⌥Space and ask Serein to use it.

The checks in this repository use the same path: `.build/debug/Serein --verify-plugins` installs `examples/plugins/notes-demo`, calls its tools through Serein’s assistant, and probes the sandbox.

## Share it

Push the folder to a public GitHub repository. Anyone can then add it in Marketplace › Plugins › Add Plugin › From GitHub… by pasting a link such as `github.com/you/serein-weather` or `github.com/you/plugins/tree/main/weather`.

Serein installs exactly one commit:
- every file must match that commit's Git blob id;
- links, submodules and redirects are refused;
- the user sees the same review as for a local folder;
- the plugin row shows the source and commit.

## Talk to Serein from your own code

A program paired in Settings › AI apps with “May ask Serein” can run:

```sh
serein-agent ask "Summarize what changed in my projects today"   # or: relay ask
serein-agent relay status
serein-agent relay stop
```

Its requests are labelled with its name, wait behind the user's own turn, and follow every choice in Settings › Assistants, what Serein asks first included.

## License

Your plugin talks to Serein over MCP and may use any license; put it in `license`.
