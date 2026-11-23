// Serein's tools for Pi. Serein loads this file with `pi --extension` in web and page tasks and
// in Relay turns only, and sets SEREIN_BROWSER_MCP to a JSON array: Serein's browser helper
// (serein-browser-mcp) and its arguments. The file starts the helper, does the MCP stdio
// handshake, registers each tool the helper lists as serein_browser_<name> and forwards every
// call. Results come back as the helper gave them, with Serein's untrusted-content markers.
// CommonJS, so it loads the same through Pi's jiti loader and through a plain import.
"use strict";
const { spawn } = require("node:child_process");

module.exports = async function sereinBrowser(pi) {
  let command;
  try {
    command = JSON.parse(process.env.SEREIN_BROWSER_MCP || "");
  } catch {}
  if (!Array.isArray(command) || command.length === 0 || !command.every((word) => typeof word === "string")) {
    throw new Error("Serein's browser is missing: start Pi from Serein.");
  }
  // Not detached: the helper stays in Pi's process group, so Serein's Stop ends both.
  const helper = spawn(command[0], command.slice(1), { stdio: ["pipe", "pipe", "inherit"] });
  const stop = () => {
    if (helper.exitCode === null && helper.signalCode === null) helper.kill();
  };
  // Pi 1.x leaves print mode by letting Node run out of work; a live helper would keep it open.
  pi.on("session_shutdown", stop);
  process.on("exit", stop);

  const pending = new Map();
  let nextID = 1;
  let ended = null;
  const end = (error) => {
    ended = ended || error;
    for (const waiter of pending.values()) waiter.reject(ended);
    pending.clear();
  };
  helper.on("error", (error) => end(new Error("Serein's browser did not start: " + error.message)));
  helper.on("exit", () => end(new Error("Serein's browser stopped.")));
  helper.stdin.on("error", () => {});
  let buffer = "";
  helper.stdout.setEncoding("utf8");
  helper.stdout.on("data", (chunk) => {
    buffer += chunk;
    for (let newline = buffer.indexOf("\n"); newline >= 0; newline = buffer.indexOf("\n")) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      const waiter = pending.get(message.id);
      if (!waiter) continue;
      pending.delete(message.id);
      if (message.error) waiter.reject(new Error(String(message.error.message || "Serein's browser refused the request.")));
      else waiter.resolve(message.result);
    }
  });
  const send = (message) => helper.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      if (ended) return reject(ended);
      const id = nextID++;
      pending.set(id, { resolve, reject });
      send({ id, method, params });
    });

  await request("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "serein-pi-extension", version: "1" },
  });
  send({ method: "notifications/initialized" });
  const listed = await request("tools/list", {});
  for (const tool of (listed && listed.tools) || []) {
    pi.registerTool({
      name: "serein_browser_" + tool.name,
      label: "Serein browser: " + tool.name,
      description: tool.description || "",
      parameters: tool.inputSchema || { type: "object", properties: {} },
      async execute(_toolCallID, params) {
        const result = await request("tools/call", { name: tool.name, arguments: params || {} });
        // Pi marks a tool result as an error only when the tool throws.
        if (result && result.isError) {
          const text = (result.content || []).map((item) => item.text || "").join("\n");
          throw new Error(text || "Serein's browser refused the request.");
        }
        return { content: (result && result.content) || [], details: {} };
      },
    });
  }
};
