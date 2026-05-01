# Codex Agent

The "Codex" Microsoft Teams bot that Dr. Kevin Yoo and MSO staff chat with. Powered by `openclaw-codex` running on `openclaw-vm` in the SDNeurosurgery Azure subscription.

This repo is the operations home for Codex — handoffs, diagnostics, recovery playbooks, and any patches we apply to the openclaw runtime.

## What's in here

- **[`HANDOFF.md`](HANDOFF.md)** — the comprehensive reference. Where the service runs, how the workspace policy files work, every patch applied to the runtime, common breakages and fixes, the diagnostic playbook. Read this first.
- **[`AGENTS.md`](AGENTS.md)** — instructions for any agent (Claude Code, Codex CLI, Cursor, etc.) working in this repo.

## What is Codex Agent (vs Yoo AI Agent)

Both run on the same VM but are completely separate services. Don't confuse them:

| Bot | App ID | Service | This repo? |
|---|---|---|---|
| **Codex** | `8d5a8a3b-82d7-45f9-bf52-962f0c8c5c9a` | `openclaw-codex.service` | ✅ Yes — this repo |
| Yoo AI Agent | `b66df7dc-8d78-4ca5-9b69-135cd0e1b7b6` | `yooai-bot` + `yooai-responder` | ❌ Separate (memory ref only) |

If a request mentions "Codex" or "the bot Alejandro/Gustavo/staff use", it's openclaw-codex — this repo.

## Quick links to common fixes

These are detailed in `HANDOFF.md`; quick pointers for triage:

- **"Codex is down" / `Unknown model: openai-codex/gpt-5.5`** → four config keys pin the model in `openclaw.json`; revert all four to `gpt-5.4`. gpt-5.5 doesn't exist on OpenAI's Codex backend yet.
- **Codex doesn't see pasted images** → check that the in-place runtime patches are still applied; verify with `journalctl | grep -E "OC-MH|OC-INBOUND-MEDIA"`.
- **Codex refuses requests / asks for Yoo's approval for a normal task** → check `IDENTITY.md`, `USER.md`, `SOUL.md` in `~/.openclaw-codex/workspace-codex/` haven't been reverted to the old tiered access model.
- **"Bot didn't get my DM"** → 90% of the time it did. Check `~/.openclaw-codex/.openclaw/agents/codex/sessions/*.jsonl` for the session matching that user's chat — the assistant's actual reply is in there.

## Service location

- VM: `openclaw-vm` in resource group `SDNeurosurgery-OpenClaw`
- Public IP: `20.9.138.12`
- Service: `openclaw-codex.service` (managed by systemd)
- Config: `/home/azureuser/.openclaw-codex/openclaw.json`
- Workspace policy files: `/home/azureuser/.openclaw-codex/workspace-codex/`
- Source (patched in place): `/home/azureuser/.npm-global/lib/node_modules/openclaw/dist/src-DAPvgbdG.js`

Use `az vm run-command invoke -g SDNeurosurgery-OpenClaw -n openclaw-vm --command-id RunShellScript --scripts "..."` for all VM access — direct SSH is flaky.
