# Saved work, recovery and updates

[← Back to Marika](../README.md)

Marika saves workspace metadata, conversations and drafts locally. Recovery actions preserve damaged data for inspection instead of silently replacing it.

## Saved work and recovery

Unsent prompts and image attachments are saved automatically and restored when you reopen the
app. Use the sidebar to find and switch projects. Each project opens its own conversation.
If an edited file has disappeared or become unreadable, its saved draft stays editable and can
be saved as a copy. Workspace and transcript files have a last good backup; Marika recovers it
automatically when possible and keeps damaged originals for inspection. Storage errors appear
at the top of the window with **Open Saved Data** and **Try Again**. Failed saves remain pending.
New sessions offer starting prompts you can review before sending. Account and billing changes
take effect after any active turn finishes, so changing settings doesn't cut off your agent.

## Checkpoints, runtime debugging and artifacts

The workspace tools menu includes **Checkpoints**, **Runtime Debugging**, and **Plans and Artifacts**.
Checkpoints capture saved files before an agent turn and compare them after it finishes. Restore
refuses to overwrite later edits or unsaved editor drafts. It restores code only, leaving chat,
commits, and Git's index intact. Git-ignored files and symlinks are excluded, with limits of 5 MB
per file and 100 MB per snapshot. The latest 12 completed snapshots per project are retained.

Runtime Debugging runs a reproduction command for up to two minutes, saves its exit status and
bounded output, and can hand the evidence to the project agent for diagnosis and verification.
Plans and Artifacts stores agent-authored plans and reports, review comments anchored to lines,
and screenshot sequences of agent browser actions. **Draft plan** starts a read-only planning
agent; **Approve and implement** continues it in the standard approval mode. Artifacts can be
reviewed across projects without putting chats in the sidebar. Agent claims in reports still
need to be assessed against their recorded evidence.

## Version information and updates

**Marika → Check for Updates…**, **Release Notes…**, and **Settings → Updates** show the installed
version and build, release notes, and the latest published GitHub release. Checks run when you ask.
No published release is reported separately from being up to date, and network failures remain
visible with a retry action. Release builds configured with an appcast and public signing key offer
**Download and Install…** through Sparkle, which verifies signed archives and feeds. Installation
checks for working agents and unsaved or saving editor documents before allowing a restart.
Development builds without a signing feed can check releases and open their download page.
