# What each approval mode does

The two agents have different safety controls, so the same mode can't always mean the same thing.
Marika's labels describe what each agent really does. The Codex column was measured against the real
binary (0.166.0-alpha.6), not taken from documentation.

| Mode | Claude Agent | Codex |
| --- | --- | --- |
| **Ask first** | Edits and commands that change things ask. Read-only commands inside the project can run without asking. | Approve every command and edit, including read-only ones. Approved commands can use the network. |
| **Accept edits** | Edits, read-only commands and file commands such as `rm`, `mv` and `cp` run inside the project without asking, including deleting folders and overwriting files. Other commands ask. | Edits to ordinary project files apply automatically. Commands still ask. So do edits outside the project or under `.git`, `.codex`, `.agents`, `.claude` or `.mcp.json`. |
| **Plan only** (Claude) / **Read only** (Codex) | Reads and plans, then you approve the plan. | Can read any file on your Mac, not just this project. There is no plan step. Changes are blocked unless the agent asks and you approve. |
| **Auto** | A safety check reviews each action and asks when unsure. | Reads any file. Changes the project and temp folders without asking, except protected folders such as `.git`. Anything else is blocked unless the agent asks and you approve. The network follows your Codex settings, and is off by default. |
| **Bypass** | No checks at all. | No checks and no sandbox. |

## How Codex maps to these

Codex has two separate controls: when to ask (`approvalPolicy`) and what the sandbox allows.

| Mode | `approvalPolicy` | Sandbox |
| --- | --- | --- |
| Ask first | `untrusted` | workspace write, network on |
| Accept edits | `untrusted`, and Marika answers file approvals itself | workspace write, network on |
| Read only | `on-request` | read only |
| Auto | `on-request` | workspace write, network from your config |
| Bypass | `never` | none |

`on-request` only prompts when a command needs to leave the sandbox, which is why it can't back a mode
that promises commands will ask. The network is on in the asking modes because each command is
approved first, and without it an approved `npm install` fails with what looks like a DNS error.

## Things worth knowing about Codex

- **Approving a command can reach further than the sandbox.** Codex doesn't say in advance whether a
  command will leave the sandbox, so every command card says it may get full access to your Mac. The
  agent can ask to run outside the sandbox, and under `untrusted` Codex can retry a blocked command
  outside it without asking again.
- **Read only and Auto don't limit reads.** Codex's sandbox allows reading anything your account can
  read, including credentials in your home folder. Limiting reads needs Codex's experimental
  permission profiles, which Marika doesn't use yet.
- **`/review` runs read-only and doesn't ask per command.** Codex forces approval off for reviews, so
  Marika reloads the thread read-only first. Bypass is the exception. `/review` and `/compact` are
  refused during a running turn, because Codex would stop that turn to run them.
- **MCP tools run outside the sandbox.** Marika asks Codex to ask before any tool that isn't marked
  read-only, on the servers in your Codex config. A tool that wrongly claims to be read-only won't
  ask, and connectors may not follow the same rule.
- **Approving a shell or REPL approves a session.** Commands typed into it won't ask again, and the
  card warns about this.
- **Changing the mode mid-turn applies when that turn ends.** A running Codex turn can't change its
  policy, so Marika shows the mode still in force and offers to stop. Claude applies changes at once.
- **A mode change can restart Codex.** Sub-agents and session-wide approvals live in the Codex process,
  so if there are any, Marika restarts it before the next turn. They then follow the new mode, and a
  sub-agent that was still running stops.
- **Bypass declines MCP forms and page requests.** Codex answers them itself, with no card.
- **Commands blocked by the sandbox can leave no row in the transcript.** Codex doesn't report them,
  so in Auto and Read only the agent's own message may be the only sign.
- **`git commit` needs to write to `.git`**, which the sandbox protects. In the asking modes it goes
  through approval. In Auto it depends on the agent asking to leave the sandbox.
- **Stop can't always end a running process.** Stop ends the turn, but a command already running can
  finish on its own.

## Folder trust

Marika never marks a folder as trusted in Codex. Threads start read-only and each turn sets the real
sandbox, because starting a thread with a writable sandbox makes Codex permanently trust the folder in
`~/.codex/config.toml` and run the repository's own MCP servers outside the sandbox.

A project's `.codex` settings therefore stay off until you trust the folder in Codex itself. Marika
shows Codex's notice when that happens.

Claude Code shows no trust prompt when driven by another app, so Marika asks before a Claude session
starts in a project with Claude configuration. It checks `.mcp.json` in every parent folder, and
`.claude` settings up to the root of the repository and in the main checkout of a linked worktree. It
asks again if a file is new or has changed. A hook added while a session is running loads without
asking, because the running CLI picks it up by itself.

## The Changes panel

The panel runs git in a folder an agent may have written to, so Marika treats that folder as hostile.
It finds the repository itself, turns off hooks and other ways git can run commands, and runs git in a
sandbox that can't write files, use the network or start other programs.
