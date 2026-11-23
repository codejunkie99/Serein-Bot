# Agents and models

[← Back to README](../README.md)

Serein does not include a chat model. It runs AI apps already on your Mac, and each app signs in with its own account. Your plan with that provider pays for the work.

## Coding agents

- Claude Code
- Codex
- Cursor Agent
- OpenCode
- Gemini CLI
- Grok
- Pi and Oh My Pi

Install the app and sign in with it. Then connect it in Serein on **Connect an AI app**, or later in Settings.

## Local models

Serein checks for model servers running on this Mac:

| Server | Address Serein checks |
| --- | --- |
| Ollama | `http://127.0.0.1:11434` |
| LM Studio | `http://127.0.0.1:1234` |

Any other OpenAI-compatible server is reached through OpenCode.

## Picking a model

The message bar shows the model, how much it thinks, and whether Serein asks first. Change any of them before you send.

## Running tasks

Up to three tasks run at once. Each runs in its own process with its own permissions. If three are running, stop one or wait for one to finish before you start another.
