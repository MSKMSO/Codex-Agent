# Session Handoff — 2026-05-01

## TL;DR

Five Teams bots live on `openclaw-vm`. Today the four older ones got security hardened (JWT verify + per-bot file scope). Gabriel's bot was built end-to-end. Alejandro's bot got thread-following + Teams file reading. MSK AI Agent renamed to Claude. Newsletter chat spam blocked at three layers.

## What's solid (ready, don't need to touch)

- **Claude** (formerly MSK AI Agent), **Yoo's bot**, **Alejandro Urich Claude**, **Gabriel's Assistant** — all running, all secured, all talking to MSO's Anthropic subscription
- Newsletter chat spam stopped at 3 layers
- Codex re-authed
- All credentials in `SDN-YooVault` (plus `SDN-KayeVault` for Kaye's separately)

## What's still open (the only real loose end)

**Kaye AI** — running, generates replies, but they aren't reaching the chat. Two things half-done:

- JWT verify patch written (`/tmp/patch-kaye-jwt.py`) but not applied
- Delivery diagnosis not finished — could be wrong chat ID, missing creds in `SDN-KayeVault`, or `send-to.sh` chain bug

## Pending (intentional defers, not blockers)

- Microsoft Graph MCP for Gabriel's bot (Phase 2)
- RingCentral integration for Gabriel's bot (Phase 3)
- Yooai bot upgrade with today's improvements (outbound logging, wide truncation) — may start hallucinating in DMs without it
- Tool-call allowlist (the third security fix we deferred this morning)

## Where to read more

The full handoff doc lives in the Virtual-Machines repo:

```
https://github.com/MSKMSO/Virtual-Machines/blob/claude/alejandro-bot-deploy/SESSION_HANDOFF_2026-04-30.md
```

It has:

- Bot fleet table with home dirs, ports, Bot Service names
- Credentials map (which secret in which vault)
- Architectural patterns established today (so next session doesn't reinvent)
- Step-by-step pickup instructions

Memory file at `memory.md` still has the standing rules: plain English, always retry. Those carry forward.

## Codex-specific notes (this repo)

Codex itself was only touched lightly today — re-authed, no other changes. The standing reference for Codex stays `HANDOFF.md` in this repo. Nothing in today's session changes the Codex runtime, model pinning, or workspace policy files.
