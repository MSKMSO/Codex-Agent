# Session Handoff — 2026-05-07

## TL;DR

Three things landed today:

1. **Real bot fleet inventoried** — 13 AI agents on `openclaw-vm`, not the "five" the 2026-05-01 handoff claimed.
2. **Azure run-command proxy went live** — this Codex-Agent session can now query the VM directly. Took a few iterations (OIDC creds, branch filter) to get there.
3. **Aixa's bot fixed** — was silently broken since deploy on 2026-05-06. Root cause: missing service principal in tenant. Fixed end-to-end. Bot now answers in personal AND group chats.

Lesson worth carrying forward: **bot OUTBOUND log entries are not proof of delivery.** The pattern `_post_reply_orig_protect` uses (`subprocess.run` + ignore returncode + log to OUTBOUND) silently swallows delivery failures. If a bot ever appears to "work but users don't see replies," check the credential chain end-to-end before trusting OUTBOUND.

## Bot fleet — the real list

13 agents, all `active running` on `openclaw-vm` as of this morning:

| Agent | Service pair | Owner | Notes |
|---|---|---|---|
| Aixa | `aixa-bot` + `aixa-responder` | Aixa Medina | Renamed to "Aixa Claude" (catalog v1.2.0). SP created 2026-05-07 — bot now actually delivers. |
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

### 5. Aixa's bot — diagnosed and fixed end-to-end

**Symptom:** Aixa Medina and Dr. Yoo reported the bot wasn't responding. Aixa's screenshot at 7:54 AM PDT confirmed: "I believe it is not working!"

**Investigation chain** (each step in `.requests/az-run-command/aixa-*.json` for reference):

1. Verified service uptime — both `aixa-bot` and `aixa-responder` running, no recent journal errors.
2. Read responder source — found 4 stale recursion errors from 2026-05-06 (already fixed by file edit at 19:29 PDT same day).
3. Reproduced post_reply with stub sender — no errors. Static call graph clean.
4. Looked at recent activity vs outbound logs. Bot DID receive Yoo's "are you here?" group-chat message and DID generate a reply. OUTBOUND logged it. So the failure was post-reply, in delivery.
5. Read SENDER script — it does check HTTP code and exits 1 on failure, but `_post_reply_orig_protect` uses `subprocess.run` and ignores the returncode. **Loss-of-signal pattern.**
6. Updated manifest to add the rename (`name.short`: "Aixa AI Agent" → "Aixa Claude") + bumped version to 1.2.0 + uploaded as new appDefinition via Graph using `yoomd-appcatalog-token.sh`. HTTP 201, displayName confirmed updated.
7. Set `AIXA_TEAMS_CATALOG_ID=05db4e89-bf71-4f52-b8b3-67f859a44c1b` env var via systemd drop-in on both services. Restarted.
8. Yoo tested again — still nothing.
9. Manually invoked SENDER against the group chat ID. Failed with `KeyError: 'access_token'` at the BF token line. The Python parsing was failing because the token endpoint returned an error.
10. Pulled the raw token error: **`AADSTS7000229: The client application is missing service principal in the tenant`**. The bot's app registration existed, but had no service principal in the SDN tenant.
11. Ran `az ad sp create --id ce03d8ce-5306-48cc-bd4f-9370d7005e15`. SP created (id `7aa929e9-f3dc-4016-b7b3-ea9ec73cdb8a`).
12. Retested BF token request — `has_token: true, expires_in: 3599`. ✓
13. End-to-end SENDER test against the real group chat ID — HTTP 201 (Created), Bot Framework returned message id `1778172467916`. Diagnostic message landed in the Aixa-Yoo chat. ✓

**Root cause:** missing service principal. Bot was never able to authenticate from the moment it was deployed. Every "successful" OUTBOUND log entry was a record of a failed delivery.

**Side benefit of the fix:** Aixa's bot is now renamed to "Aixa Claude" in the org catalog (Teams clients will pick up the new name within a couple hours).

**Worth applying to other recent bots:** Aixa was a fresh deploy. Other recently-created bots (Zahid was today, Rosi/David/Neil/Heather are recent) could have the same missing-SP bug. Quick check command: `az ad sp show --id <bot-app-id>`. If it errors with "does not exist," the SP is missing — fix with `az ad sp create --id <app-id>`.

**Permanent improvement worth doing:** patch `_post_reply_orig_protect` in every responder to capture and log SENDER's stderr + returncode on non-zero exit. One-line fix. Saves us from chasing this same kind of silent failure on a different bot in the future.

## Standing loose ends from previous handoffs

- **Kaye AI** — generates replies, replies don't reach the chat. JWT verify patch at `/tmp/patch-kaye-jwt.py` written but not applied. Delivery diagnosis unfinished. **Now strongly suspected to be the same root cause as Aixa's** — missing service principal. Worth checking before any further JWT-side investigation.
- **Yooai bot** — has not received the outbound logging / wide truncation improvements applied to other bots. May start hallucinating in DMs without it.
- **Tool-call allowlist** — third security fix from the 2026-04-30 hardening pass, deferred.
- **Dr. Marsh's Outlook mail rules** for filtering Teams digest emails — scoped earlier this session, not implemented.
- **Microsoft Graph MCP** for Gabriel's bot (Phase 2) and **RingCentral integration** (Phase 3) — both still queued.

## Standing rules

- Plain English. The user (Dr. Yoo, Gabriel, MSO staff) is not a software engineer.
- Always retry — don't surface flaky errors as user problems.
- VM access from this session is via the proxy, not direct. Round-trips are 30–60s.
- This session is hard-scoped to `mskmso/codex-agent`. Other repos (Virtual-Machines, etc.) require a separate session.
