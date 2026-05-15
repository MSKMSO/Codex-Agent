# Instructions for Claude Code working on Codex Agent

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

## When ANY Claude bot returns "Had trouble generating a reply" — read this first

The same Teams-side error message can come from at least four very different causes (Anthropic rate limit, broken responder code from a bad auto-injection, dead service, harmless Graph 404). **Run the diagnostic in [`docs/bot-empty-reply-diagnosis.md`](docs/bot-empty-reply-diagnosis.md) BEFORE doing anything.** It has the decision tree from the responder error/debug logs and the safe source-repair pattern for the auto-injection trap that bit us on 2026-05-14.

**Do NOT** reach for the token-file copy recipe (`docs/reference_bot_claude_token_fix.md`) before running the diagnosis — copying one bot's `/etc/claude-tokens/*.env` onto another's silently rebinds the receiver to the source's AAD and merges their Anthropic quota. The token-copy recipe applies ONLY when the diagnosis confirms a bot's own `.env` is genuinely truncated (Pattern A subcase) — never as a "try this first" shortcut.

## When debugging the OTHER Teams bots — read this first

If the user's question is about Emily / Neil / Stephanie / Aixa / Zahid / David / Rosi / Gabriel / Alejandro / Heather / Kaye / Claude / Yoo AI — i.e., any of the templated Claude or OpenAI bots running on `openclaw-vm` — read [`docs/multi-bot-debugging.md`](docs/multi-bot-debugging.md) before writing a single command. ("Claude" is the main no-user-prefix Claude bot; internal service name is `mskai-bot.service` / `mskai-responder.service` for grep purposes.) The doc encodes the diagnostic order learned from real multi-hour debug sessions, including:

- **The diff-first rule** for templated bot families. When one twin works and the others don't, your first command is `diff` between their responder/bot files. Not `az bot show`. Not `curl`. `diff`.
- **The single most common failure mode**: `creds.json` containing the secret **ID** instead of the secret **value** → `AADSTS7000215`. Fix at [`docs/runbook-rotate-bot-secret.md`](docs/runbook-rotate-bot-secret.md).
- The proven order to check things (services running → BF auth → endpoint URL match → responder code drift → Teams channel → chat install).
- Anti-patterns to avoid — chiefly **assuming the URL is wrong without verifying**, which has eaten multiple hours.

This applies whenever a sibling bot is acting up. Don't guess; diff.

## When a user reports "wrong chat" on Claude — read this first

If the user says Claude (the main no-user-prefix Claude bot, internal service `mskai-responder`) is replying in the wrong chat, **read [`docs/2026-05-13-claude-wrong-chat-non-incident.md`](docs/2026-05-13-claude-wrong-chat-non-incident.md) before reading any responder code.** The 2026-05-13 investigation looked at every code path and the full inbound/outbound log (1,469 in, 681 out, 48 chats including DMs) and found **zero misroutes**. Re-run the log comparison first (the query is at `.requests/az-run-command/claude-routing-diag-20.json`); if still zero, the cause is almost certainly a Teams client display artifact, not the bot. Don't edit the responder for this symptom without a concrete repro (chat-asked, chat-replied, timestamp).

## When per-user bots return "Had trouble generating a reply" — read this first

If the 16 per-user Claude bots (Aixa/Alejandro/Ashley/Axel/Cameron/David/Emily/Jesus/Jose/Lia/Neil/Neil-Claude/Rosi/Stephanie/Zahid/Afrah) all post the **"Had trouble generating a reply"** fallback while Claude (mskai) and Yoo AI are fine, the symptom is almost always: `/home/azureuser/.claude/.credentials.json` was refreshed by Claude CLI and dropped to mode 0600, blocking per-user accounts (who only have group-read via the `azureuser` group through the symlinked `.claude`). **Read [`docs/2026-05-13-per-user-bot-credential-outage.md`](docs/2026-05-13-per-user-bot-credential-outage.md) before touching anything.**

An azureuser cron entry (`* * * * * /home/azureuser/.claude-cred-chmod.sh`) re-applies mode 0640 every minute, so the symptom should self-heal within 60 seconds. If it's persistent, first check `crontab -u azureuser -l` and `stat -c '%a' /home/azureuser/.claude/.credentials.json` (should be 640). Manual one-line fix if the cron is missing or broken:

```bash
chmod 0640 /home/azureuser/.claude/.credentials.json
```

**Do NOT run `chown -R` on any per-user `.claude` directory.** Those are symlinks back to `/home/azureuser/.claude`. Recursion will follow the symlinks and corrupt the master credential, breaking Claude (mskai).

**Do NOT try to give each per-user bot its own real `.claude/` + copied `.credentials.json`.** That's the trap I fell into on 2026-05-13. A copy of the credential file produces `rc=0` with empty stdout — Claude CLI silently fails when the credential lacks matching device/session state (which only an interactive `claude /login` can generate).

**Do NOT try the `CLAUDE_CODE_OAUTH_TOKEN` env-var path either.** Also tested 2026-05-13: with HOME=tempdir + env var only, the CLI returns `Your organization does not have access to Claude. Please login again or contact your administrator.` That's Anthropic's seat/session binding, not a credential problem — the OAuth token is valid; the per-user device just isn't registered as a seat. Heather/Kaye/Gabriel work only because someone interactively ran `claude /login` in their HOME long ago; that registration cannot be reproduced programmatically. **The current architecture IS the terminal architecture** — symlinks + azureuser group + 0640 master + chmod cron is the supported steady state. There is no migration to finish. (No-op env-var infrastructure was left in place — `claude-bot-token-refresh.service`/`.timer`, `EnvironmentFile=-/run/claude-bot-token.env` drop-ins — as harmless scaffolding only.)

**Onboarding a new bot:** create the per-user Linux account, add to `azureuser` group, create `~/.claude` as a symlink to `/home/azureuser/.claude` (`chown -h` the symlink to the new user). Done. Don't run `claude /login`. Don't copy `.credentials.json`. Don't make a real `.claude/` dir.

**Critical mode for `/home/azureuser`:** must be `0711`, NOT `0750`. The 16 group-member bots traverse via group (either mode works for them), but the 3 isolated bots (heather, kaye — NOT in `azureuser` group) need world traverse-only to exec `/home/azureuser/.npm-global/bin/claude`. Setting `/home/azureuser` to `0750` silently breaks heather and kaye (gabriel still works because gabriel has dual group membership). Symptom: their bots receive inbound from Teams but never reply — `claude` exec fails with `Permission denied`, and the responder either falls back to "Had trouble generating a reply" or posts nothing.

## When creating a new bot from scratch — read this first

Dr. Yoo's "build a new bot for <user>" request is the highest-leverage moment to follow the playbook exactly. **Read [`docs/bot-creation-end-to-end.md`](docs/bot-creation-end-to-end.md) start to finish before doing ANY work.** It now has seven phases (Preflight, Entra+BotService, VM service files, Teams catalog publish, Install, Health check, Dr. Yoo identifier wiring), each with mandatory verify gates.

**Phase 0 (Preflight) is non-negotiable** — run [`scripts/preflight-bot-creation.sh`](scripts/preflight-bot-creation.sh) before anything that creates state. It catches:
- Tenant Teams App Permission Policy gate closed (the 2026-05-11 wall — wasted ~6 hours)
- AppPublisher / YooMD refresh tokens expired
- Reference bot health pre-existing problems

If preflight fails, **STOP and escalate**. Don't try to power through.

**Phase 6 (Dr. Yoo identifier wiring) is mandatory for every new bot.** Every bot in the fleet must be wired to Dr. Yoo's professional identifiers (NPI, license, addresses) — Tier 1 (hardcoded) for the three personal agents (Dr. Yoo's Anthropic Agent, Dr. Yoo's OpenAI Agent, Dr. Heather's AI Agent), Tier 2 (vault-fetched from `SDN-YooVault` → `dr-yoo-identifiers`) for everyone else. **The default for any new bot is Tier 2.** See Phase 6 in [`docs/bot-creation-end-to-end.md`](docs/bot-creation-end-to-end.md) for the wiring scripts (`tier1-embed-identifiers.py` / `tier2-wire-vault-fetch.py`), the never-fill list (banking, SSN, DEA, DOB, DL, signatures), and the verification step (Teams test: `"What's Dr. Yoo's NPI?"` should return `1295774545`).

## When publishing or installing a Teams app — read this first

If the user's question is about uploading a new bot to the Teams catalog, installing a bot in someone's personal Teams, or debugging an `App is blocked by app permission policy` 403, read [`docs/teams-app-publishing.md`](docs/teams-app-publishing.md) **before** any `POST /appCatalogs/teamsApps` call. It encodes the rules learned from the 2026-05-11 incident where MSO Claude triggered Microsoft's anti-abuse cooldown via repeated upload-delete-reupload and bricked six apps for ~24h.

The five rules in summary:
1. **One upload, one app, forever.** Version updates via `POST .../appDefinitions`, never via fresh `POST .../teamsApps`.
2. **Verify-before-retry.** When install returns 403, FIRST do `GET /v1.0/appCatalogs/teamsApps/{id}`. If 404, the app is gone; retrying is pointless and harmful.
3. **Verify success after upload.** 201 doesn't mean published. Poll `displayName` filter for up to 5 minutes; if it doesn't appear, the upload was silently rejected.
4. **403 "blocked by app permission policy" is ambiguous.** It can mean a real policy block OR a stale-cache reference to a deleted app. Always run rule 2 first.
5. **Stop signal.** If you've done >2 upload-delete cycles on the same logical app in an hour, STOP. You've triggered Microsoft's anti-abuse logic; continuing makes it worse.

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
