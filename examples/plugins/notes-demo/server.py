"""A minimal MCP server over stdio, standard library only: a template for Serein plugins.

Serein starts it for each call, in a sandbox: it may write only in SEREIN_PLUGIN_DATA and has
no network (its manifest lists no hosts). Every tool it offers is listed in serein-plugin.json
with its risk; Serein sees only those.
"""
import json, os, sys

DATA = os.environ.get("SEREIN_PLUGIN_DATA", ".")
NOTES = os.path.join(DATA, "notes.json")

TOOLS = [
    {"name": "list_notes", "description": "List the saved notes.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "add_note", "description": "Save a short note.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"],
                     "additionalProperties": False}},
    {"name": "clear_notes", "description": "Delete every saved note.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
]

def load():
    try:
        with open(NOTES) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []

def save(notes):
    with open(NOTES, "w") as f:
        json.dump(notes, f)

def call(name, args):
    if name == "list_notes":
        notes = load()
        return "\n".join("- " + n for n in notes) or "No notes yet."
    if name == "add_note":
        notes = load() + [str(args.get("text", ""))[:500]]
        save(notes)
        return "Saved. %d notes." % len(notes)
    if name == "clear_notes":
        save([])
        return "Cleared."
    raise ValueError("unknown tool " + name)

def reply(mid, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": mid}
    if error is None:
        message["result"] = result
    else:
        message["error"] = {"code": -32000, "message": error}
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        continue  # a notification
    if method == "initialize":
        reply(mid, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                    "serverInfo": {"name": "notes-demo", "version": "1.0.0"}})
    elif method == "tools/list":
        reply(mid, {"tools": TOOLS})
    elif method == "tools/call":
        params = msg.get("params", {})
        try:
            text = call(params.get("name"), params.get("arguments") or {})
            reply(mid, {"content": [{"type": "text", "text": text}]})
        except Exception as e:  # report the failure as a tool error
            reply(mid, {"content": [{"type": "text", "text": str(e)}], "isError": True})
    else:
        reply(mid, error="method not found")
