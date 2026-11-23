# Permissions and safety

[← Back to README](../README.md)

## What Serein asks about

**Serein asks before** has three levels. Change it in **Settings › Assistants › Asks first**, or from any approval card.

| Level | What happens |
| --- | --- |
| Every step | Serein asks before each action on your Mac and before it starts a task. |
| Only risky steps | Serein asks before it sends, posts, buys, deletes, signs out, or uses Terminal or System Settings. Routine steps go ahead. A new install starts here. |
| Allow all | Serein and its tasks go ahead without asking. Paying and passwords go to a secure card you fill. |

Paying always stays with you, at every level.

## What a task can touch

Each task shows its grants while it runs.

| Grant | Default |
| --- | --- |
| Click and type on sites | Off until you turn it on. |
| Act in Mac apps | Off until you turn it on. Serein shows the script before it runs. |
| Edit files in a project | On until you turn it off. |
| Sign in on sites | Separate tabs with no sign-ins, unless you allow them for the task. |

A delegated project task that may edit files starts in Auto mode, which asks before risky commands. It gets Full access only after you confirm Full access for that project.

## Undo

Before a turn changes a project, Serein snapshots the working tree as a Git tree under `refs/serein/turns/<run>/`. Undo restores the turn from that snapshot. Serein never commits or pushes these refs, and never touches your index, branches, stash or config.

## Your data

- History, projects and conversations are stored in `~/Library/Application Support/Serein/Library`.
- A task and its context go to the AI app you chose. That app sends them to its provider under your account.
- Serein needs no Serein account.
