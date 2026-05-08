# Instructions for agents working on Codex Agent

This repo is the home for everything related to **Codex Agent** — the openclaw-codex Teams bot that Dr. Yoo and MSO staff chat with as "Codex" in Microsoft Teams. If the user asks about Codex, the openclaw bot, why it's down, why it isn't reading images, why it's refusing requests, or anything related to its model / policy / workspace files, this is your starting point.

## Top rule: always plain English

**This is the #1 standing instruction. Do not skip it.**

The people you're talking to (Dr. Yoo, Gabriel, MSO staff, anyone in this org) are not software engineers. Every chat reply, summary, status update, or "what happened" explanation defaults to plain language a smart non-technical person can read once and understand. If you catch yourself writing acronyms, command names, HTTP codes, or jargon as the main message, rewrite it.

- **Do**: "The bot can't post in group chats because Microsoft has the wrong address on file. I'm checking what address it has, then I'll fix it."
- **Don't**: "The Bot Framework messaging endpoint URL in the Microsoft.BotService/botServices resource is misconfigured — Teams is hitting `/emily/api/messages` which 404s instead of the nginx-routed `/emily-claude/api/messages`."

Rules of thumb:

- Skip acronyms unless you define them once.
- Lead with the bottom line. "It's fixed. Here's what was wrong" before "Here's the diagnostic chain that got me there."
- Use analogies for technical concepts ("think of it like..." / "it's the same as...").
- Commands and code go in code blocks for reference; the surrounding prose stays plain.
- If asked, you can give the technical version too — but the first paragraph is always plain English.

This applies to chat replies, summaries, status updates, and explanations. It does **not** apply to commit messages, PR descriptions, file contents, or code comments — those stay technical.

## First step every session

**Read [`HANDOFF.md`](HANDOFF.md) before doing anything else.** It is the canonical reference for:

- Where the service runs (openclaw-vm) and how it differs from Yoo AI Agent (different bot, different process — easy to confuse)
- The four config keys that pin the model (gpt-5.5 doesn't exist on the Codex backend yet — keep on gpt-5.4)
- Six in-place patches in the openclaw runtime (image fetch broadening, history-aware media fallback, diagnostic traces) — with re-apply instructions if a future `npm update` clobbers them
- The workspace policy files (`IDENTITY.md`, `USER.md`, `SOUL.md`) that govern user access and refusal behavior
- Diagnostic playbook with copy-pasteable journalctl commands
- The five recurring breakages and the exact fix for each

Don't try to debug Codex from scratch — start with `HANDOFF.md`.

## Work silently

Don't ping the user with intermediate "I'm checking…" messages. Run the diagnostic, fix the thing, then report the outcome in one message. The four-field summary format Dr. Yoo prefers: what I did / which thing was affected / what to verify / what's next.

## Diff-first when sibling bots diverge

**If a bot is broken and a sibling bot from the same template works, the FIRST diagnostic step is `diff <broken>.py <working>.py`.** Not "check the secret," not "check the URL," not "check the manifest." Diff first.

The bots on `openclaw-vm` are stamped from the same template (`make-mso-claude-bot.sh`). When one is silent and another isn't, the difference is usually a single sed-able edit visible in 30 seconds of diff output. Going hunting through credentials, network paths, allow-lists, and ARM resources without doing the diff first wastes round-trips.

Concrete example from 2026-05-08: Emily/Neil/Stephanie were silent. Aixa worked. Five bugs were chased in sequence (vault secrets, URL hyphens, allow-list, restart issues, recursion bug) before the actual fix — a duplicate `_post_reply_orig_protect` definition causing infinite recursion — was found. A `diff aixa-responder.py emily-claude-responder.py | head -30` at step 1 would have shown the duplicate definition immediately.

Rule: when symptoms are "bot exists but doesn't reply" and a known-working sibling exists, dump the diff before doing anything else.

## Never delete unless explicitly asked

If a fix involves deleting a file, a backup, a session, or a config block, **back it up first** and never run destructive commands without showing the plan. The runtime has a habit of caching everything per session — a wrong delete can wipe live conversations. The handoff describes the safe fix paths.

## What "openclaw-vm" means

The bot runs on a single Azure VM in the SDNeurosurgery subscription:

- VM: `openclaw-vm` in resource group `SDNeurosurgery-OpenClaw`
- Public IP: `20.9.138.12`
- FQDN: `openclaw-sdneuro.westus2.cloudapp.azure.com`

SSH from outside is unreliable in practice. Use Azure run-command for everything:

```bash
az vm run-command invoke -g SDNeurosurgery-OpenClaw -n openclaw-vm --command-id RunShellScript --scripts "<command>"
```

The run-command extension serializes — if it errors with `Conflict: Run command extension execution is in progress`, wrap in a retry loop:

```bash
until az vm run-command invoke -g SDNeurosurgery-OpenClaw -n openclaw-vm --command-id RunShellScript --scripts "$SCRIPT" --query "value[0].message" -o tsv 2>/tmp/rc.err; do sleep 5; done
```

## Repo layout

- [`HANDOFF.md`](HANDOFF.md) — the comprehensive reference. Read this first.
- [`README.md`](README.md) — short summary of what Codex Agent is and how it fits into the MSO infrastructure.
- `docs/` — additional reference material (diagnostic scripts, recovery playbooks, model upgrade notes) as the operations grow.
- `patches/` — saved copies of the in-place runtime patches in case the npm package gets overwritten and you need to re-apply them quickly.
