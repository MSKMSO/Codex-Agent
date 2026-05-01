# Instructions for agents working on Codex Agent

This repo is the home for everything related to **Codex Agent** — the openclaw-codex Teams bot that Dr. Yoo and MSO staff chat with as "Codex" in Microsoft Teams. If the user asks about Codex, the openclaw bot, why it's down, why it isn't reading images, why it's refusing requests, or anything related to its model / policy / workspace files, this is your starting point.

## First step every session

**Read [`HANDOFF.md`](HANDOFF.md) before doing anything else.** It is the canonical reference for:

- Where the service runs (openclaw-vm) and how it differs from Yoo AI Agent (different bot, different process — easy to confuse)
- The four config keys that pin the model (gpt-5.5 doesn't exist on the Codex backend yet — keep on gpt-5.4)
- Six in-place patches in the openclaw runtime (image fetch broadening, history-aware media fallback, diagnostic traces) — with re-apply instructions if a future `npm update` clobbers them
- The workspace policy files (`IDENTITY.md`, `USER.md`, `SOUL.md`) that govern user access and refusal behavior
- Diagnostic playbook with copy-pasteable journalctl commands
- The five recurring breakages and the exact fix for each

Don't try to debug Codex from scratch — start with `HANDOFF.md`.

## Talk in plain English

Dr. Yoo isn't a software engineer. Write the way you'd explain something to a smart friend who doesn't work in tech.

- **Do**: "Codex stopped responding because someone changed the model to a version that doesn't exist yet. Fixing it now."
- **Don't**: "FailoverError raised on warmup; the openai-codex provider catalog has no entry for `gpt-5.5` and the upstream `chatgpt.com/backend-api` returns model_not_found."

Rules of thumb:

- Skip acronyms when you can.
- No unexplained command-line jargon in prose. Commands belong in code blocks; explanations belong in plain text.
- Lead with the bottom line. "Codex is back up — model was set to one that doesn't exist" before "I reverted four config keys and restarted the gateway."
- If something is broken, say what's broken and what you'd do next. Skip the diagnostic trace unless asked.

This applies to chat replies, summaries, status updates, and "what happened" explanations. It does **not** apply to commit messages, PR descriptions, or code/script comments — those stay technical.

## Work silently

Don't ping the user with intermediate "I'm checking…" messages. Run the diagnostic, fix the thing, then report the outcome in one message. The four-field summary format Dr. Yoo prefers: what I did / which thing was affected / what to verify / what's next.

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
