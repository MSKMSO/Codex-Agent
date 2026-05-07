# Session Handoff — 2026-05-07

## TL;DR

The "five Teams bots" line in yesterday's handoff was wrong. There are **13 AI agents** running on `openclaw-vm`. New proxy mechanism is live so this Codex-Agent session can now query the VM directly without bouncing to a Virtual-Machines session for every read.

## Bot fleet — the real list

13 agents, all `active running` on `openclaw-vm` as of this morning:

| Agent | Service pair | Owner | Notes |
|---|---|---|---|
| Aixa | `aixa-bot` + `aixa-responder` | Aixa Medina | New, came online 2026-05-06 |
| Zahid | `zahid-bot` + `zahid-responder` | Muhammad Zahid | New, came online 2026-05-06 |
| Alejandro | `alejandro-bot` + `alejandro-responder` | Alejandro Urich | V1.2 manifest spec drafted in `handoffs/alejandro-bot/` |
| Gabriel | `gabriel-bot` + `gabriel-responder` | Gabriel Garcia | V1.2 manifest deployed; spec in `handoffs/gabriel-bot/` |
| Rosi | `rosi-bot` + `rosi-responder` | **TBD** — owner not yet recorded |
| David | `david-bot` + `david-responder` | **TBD** — owner not yet recorded |
| Neil | `neil-bot` + `neil-responder` | **TBD** — owner not yet recorded |
| Heather | `heather-bot` + `heather-responder` | **TBD** — owner not yet recorded |
| Kaye | `kaye-bot` + `kaye-responder` | Kaye | The "replies not reaching chat" loose end from 2026-04-30 handoff |
| Claude | `mskai-bot` + `mskai-responder` | (shared / general) | Formerly "MSK AI Agent" |
| Yoo (Anthropic) | `yooai-bot` + `yooai-responder` | Dr. Yoo | |
| Yoo (OpenAI) | `yooopenai-bot` + `yooopenai-responder` | Dr. Yoo | Separate OpenAI-backed twin |
| Codex | `openclaw-codex` (single service) | (shared, this repo's bot) | No responder pair — different architecture |

Plus `whatsapp-bridge.service` — an integration, not a bot.

**Open question:** owners for Rosi, David, Neil, Heather. Next time someone has VM access, drop a `cat ~/.{rosi,david,neil,heather}-bot/IDENTITY.md` (or wherever the owner is recorded) and fill the table in.

## What's new this session

### 1. Azure proxy is live for this repo

Dr. Yoo built and Gabriel verified an Azure run-command proxy specifically for the Codex-Agent repo session. Mechanism:

- Workflow: `.github/workflows/dispatch-az-run-command.yml`
- Docs: `docs/dispatch-az-run-command.md`
- Request: commit `.requests/az-run-command/<id>.json` with `{"vm":"openclaw-vm","script":"..."}`
- Response: lands at `.responses/az-run-command/<id>.json` after ~30–60s
- Backed by OIDC SP `sp-mso-cc-openclaw-diag` with **OpenClaw Run Command Operator** custom role (read VM, run shell, read output — no start/stop/delete/modify of the VM itself)
- Limited to `openclaw-vm` — other VMs need a separate role assignment

**OIDC federated credentials** (added 2026-05-07 by Dr. Yoo):
- `repo:MSKMSO/Codex-Agent:ref:refs/heads/main` (original)
- `repo:MSKMSO/Codex-Agent:ref:refs/heads/claude/write-session-handoff-qbuwZ` (this session's branch)
- `repo:MSKMSO/Codex-Agent:pull_request` (any PR-event run)

For future sessions on different feature branches: easiest path is to **commit request files directly to `main`** via `create_or_update_file`. If the harness forces a different branch and OIDC fails with `AADSTS700213`, ping Dr. Yoo to add a cred for that branch name (5-second change).

### 2. Workflow patched for branch-agnostic operation

Workflow YAML now has:
- Explicit `branches: ['**']` under push trigger.
- `workflow_dispatch:` manual trigger as a fallback.
- A "Diagnostic context" first step that prints branch / sha / event / visible request files. Means future silent failures have visible cause.

### 3. Gabriel's bot V1.2 deployed

V1.2 manifest (group-chat + team-channel scope) was uploaded to Teams Admin Center for Gabriel's bot. Some delivery issue — the bot wasn't appearing as installable in group chats from the user's end at last check. Suspected causes (in order): Teams cache not refreshed, tenant app permission policy blocks custom apps in group chats, or the upload version didn't actually land. Still open.

### 4. Alejandro's bot V1.2 spec written

Spec at `handoffs/alejandro-bot/V1.2_SPEC.md`. Three changes scoped: group-chat manifest scopes, conversation-memory verification (yesterday's "thread-following" work may already cover it), and a per-user notes file for adaptive learning. Built but not yet deployed — needs a Virtual-Machines session.

A separate Virtual-Machines session built an Alejandro V1.2 zip on branch `claude/alejandro-manifest-v1.2`. Status of upload unknown from this session.

## Standing loose ends from previous handoffs

- **Kaye AI** — generates replies, replies don't reach the chat. JWT verify patch at `/tmp/patch-kaye-jwt.py` written but not applied. Delivery diagnosis unfinished.
- **Yooai bot** — has not received the outbound logging / wide truncation improvements applied to other bots. May start hallucinating in DMs without it.
- **Tool-call allowlist** — third security fix from the 2026-04-30 hardening pass, deferred.
- **Dr. Marsh's Outlook mail rules** for filtering Teams digest emails — scoped earlier this session, not implemented.
- **Microsoft Graph MCP** for Gabriel's bot (Phase 2) and **RingCentral integration** (Phase 3) — both still queued.

## Standing rules

- Plain English. The user (Dr. Yoo, Gabriel, MSO staff) is not a software engineer.
- Always retry — don't surface flaky errors as user problems.
- VM access from this session is via the proxy, not direct. Round-trips are 30–60s.
- This session is hard-scoped to `mskmso/codex-agent`. Other repos (Virtual-Machines, etc.) require a separate session.
