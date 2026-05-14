# Instructions for agents working on Codex Agent

This repo is the home for everything related to **Codex Agent** — the openclaw-codex Teams bot that Dr. Yoo and MSO staff chat with as "Codex" in Microsoft Teams. If the user asks about Codex, the openclaw bot, why it's down, why it isn't reading images, why it's refusing requests, or anything related to its model / policy / workspace files, this is your starting point.

## Top rule: always plain English

**This is the #1 standing instruction. Do not skip it. This rule applies to EVERY chat reply you send, including status updates, "I'm waiting on…", and "the proxy is wedged" messages — not just final answers.**

The people you're talking to (Dr. Yoo, Gabriel, MSO staff, anyone in this org) are not software engineers. Every chat reply, summary, status update, error report, or "what happened" explanation defaults to plain language a smart non-technical person can read once and understand. If you catch yourself writing acronyms, command names, HTTP codes, or jargon as the main message, **rewrite it before sending**.

- **Do**: "The bot can't post in group chats because Microsoft has the wrong address on file. I'm checking what address it has, then I'll fix it."
- **Don't**: "The Bot Framework messaging endpoint URL in the Microsoft.BotService/botServices resource is misconfigured — Teams is hitting `/emily/api/messages` which 404s instead of the nginx-routed `/emily-claude/api/messages`."

Specific words and phrases that are almost always violations of this rule when used as the main message (not in code blocks or footnotes):

- HTTP status codes: "403", "404", "201", "exit 1"
- Microsoft jargon: "Graph install", "AAD", "TAC", "tenant policy", "AppCatalog", "Bot Framework"
- Infrastructure jargon: "proxy", "run-command", "queue wedge", "dispatch", "OIDC"
- File/system paths in prose: `/home/azureuser/...`, `~/.claude/`, "systemd unit"
- API/object names: "endpoint", "catalog id", "manifest", "responder.py"

If you must reference one of these to be precise, put it in a code block or parenthetical AFTER the plain-English sentence. Example: "Heather's bot got removed from the org-wide app list yesterday (catalog id `922fe8e1-…`)." — the plain sentence stands alone; the id is a footnote.

Rules of thumb:

- Skip acronyms unless you define them once.
- Lead with the bottom line. "It's fixed. Here's what was wrong" before "Here's the diagnostic chain that got me there."
- Use analogies for technical concepts ("think of it like..." / "it's the same as...").
- Commands and code go in code blocks for reference; the surrounding prose stays plain.
- If asked, you can give the technical version too — but the first paragraph is always plain English.
- **"Status update" doesn't excuse jargon.** A message that says "proxy wedged, queue full, dispatching retry" is still a chat reply to Dr. Yoo and still has to read as plain English. Rewrite as: "My connection to your Mac is stuck and I'm waiting for it to come back."

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

## Read 4xx error bodies literally — don't guess at causes

When a Microsoft Graph or Azure REST call returns 403/401, **the error body says what's actually wrong**. Read it literally. Don't pattern-match a phrase and jump to a fashionable hypothesis.

Concrete example from 2026-05-08: `POST /users/{id}/teamwork/installedApps` returned `403 Forbidden` with `"App is blocked by app permission policy"`. I assumed "tenant policy block" and spent multiple round-trips trying to bypass it — granting more app roles, attempting tenant settings updates, etc. The actual cause was **missing scopes on the delegated token** (`TeamsAppInstallation.ReadWriteForUser.All` and `AppCatalog.ReadWrite.All` weren't in the YooMD oauth2PermissionGrant). The "policy" wording in the error came from Microsoft's catch-all message; once the scopes were added to the YooMD grant and the refresh token rotated, install worked first try.

Rule:
- `403` on Microsoft Graph → first check the **scopes on the token** (decode the JWT or check `scope` returned by the token endpoint). Don't move past this until you've confirmed scopes match what the API requires.
- `401 AADSTS65001` → consent / scope issue.
- Only after eliminating scope-side causes should you investigate tenant policies, conditional access, or RBAC.

## Catalog upload → user install: do it ONCE per bot, no retries

**Critical rule discovered the hard way on 2026-05-11:** after ~3 upload-delete-reupload cycles on `appCatalogs/teamsApps` against the same tenant within a few hours, Microsoft's anti-abuse layer silently quarantines every new upload. The API keeps returning `201 Created` with a new catalog id, but the entry is never actually published — `GET /v1.0/appCatalogs/teamsApps/{id}` returns 404, the catalog list query returns 0 matches by displayName, and the user-install endpoint returns `403 "App is blocked by app permission policy. AppType: Private"`.

The 403 error message is a red herring. It's not a real policy block. It fires because the install endpoint reads from a different backstore than the public catalog list, and that backstore has stale references to the deleted apps. The user-policy check passes/fails on `AppType: Private` from a cache; the real failure is upstream — the app simply isn't published.

Symptoms you're in this state:
- `GET /v1.0/appCatalogs/teamsApps/{your-just-uploaded-id}` → 404
- `GET /v1.0/appCatalogs/teamsApps?$filter=startswith(displayName,'YourApp')` → `count=0`
- `POST /users/{id}/teamwork/installedApps` → 403 "App is blocked by app permission policy"
- Waiting 60/90/120 minutes does not change any of this — the apps were never published, they're not propagating slowly

What to do:
1. **One upload per bot. Period.** No delete-and-reupload. If a single upload doesn't appear in the catalog list within ~5 minutes, stop, investigate, do not retry. Filing an investigation = grep the actual error body, decode the JWT, check the catalog list — but **do not upload again**.
2. **Never delete a catalog entry that has installs against it.** Catalog DELETE cascades to remove the install from every user (documented in the section below). Privacy is enforced inside the bot's allow-list, not by hiding the catalog entry.
3. If you've already burned the cooldown budget for the day: stop. Wait ~24 hours for Microsoft's anti-abuse cooldown to lift. Then resume with rule #1.

Concrete case study from 2026-05-11 (Jose Sotillo + Axel Manosalvas + Lia Lopez deployments):
- 15:23 UTC: Phase A uploaded `Jose Claude` (d927ccfc) and `Axel Claude` (e1a45203). Worked. Installed successfully at 16:48 (85-min wait was real propagation, this once).
- 17:01 UTC: catalog DELETEd those entries to "make private." Cascade-uninstalled both from users.
- 17:13 UTC: reup2 uploaded fresh entries (8cdd25e7, 8ac71d00). `201 Created` returned. Catalog list never showed them. All subsequent install attempts 403'd.
- 18:48 UTC: fresh-upload tried *again* with new manifests (50d6b84e, 6e404205) + Lia (28021e9a). Same outcome — 201, then 404/0-count, then 403 forever.
- 19:31 UTC: confirmed via direct GET that every catalog id this session generated (six of them, including Jesus/Cameron/Afrah morning IDs) returned 404. The cooldown was real and global to that day's session.

The "85-minute propagation" hypothesis was wrong. The first Phase A upload happened to slip through before the cooldown engaged; everything after that was quarantined and the wait was meaningless. Don't repeat that mistake — if the catalog list doesn't show the entry within minutes, the upload didn't actually publish, and more waiting won't fix it.

Symptoms that confirm "this is the delay, not a real policy block":
- The `$expand=appDefinitions` list shows your entry with `publishingState: 'published'`.
- Direct GET by catalog id returns 404 (admin-distributed entries don't index for GET until propagated).
- Other already-existing org apps (e.g. `Cameron Claude`, `Dr. Yoo's Open AI Agent`) install fine for the same target user.
- Chat-scope install (`POST /chats/{chatId}/installedApps`) of the same app id succeeds 201 immediately — only user-scope install is gated.

What to do:
1. Finish phase A (upload + bot resource + manifest).
2. Move on — deploy code under the Linux user, get services running.
3. After ~1 hour from upload, run user install. It will succeed 201.
4. **Leave the catalog entry in place.** See the next section for why.

Do **not** retry the install repeatedly during the 1-hour window — it just burns proxy round-trips. Do **not** mint new tokens, change scopes, ask for reconsent, or re-upload the manifest; none of those fix it. Wait the hour.

## Do NOT delete the catalog entry after install — it cascade-uninstalls from the user

**Deleting a teamsApp from the org catalog (`DELETE /appCatalogs/teamsApps/{id}`) also removes every existing install of that app from every user.** This was assumed-safe under the previous "make private by delete" pattern; it is not.

Concrete pattern from 2026-05-11: after `Jose Claude` and `Axel Claude` were successfully installed for their users (HTTP 201), the catalog DELETE returned 204 — and a subsequent `GET /users/{id}/teamwork/installedApps?$expand=teamsApp` showed the bots gone from both users. Same retroactively explains why yesterday's Afrah Claude install does not appear in Afrah's installed apps today (the catalog was deleted yesterday afternoon).

Privacy is enforced **inside the bot**, not in the catalog. Every responder script has an allow-list (`USER_AAD_ID` plus `YOO_AAD_ID`) that silently refuses messages from anyone else (Phase B8 of the runbook patches this in). Even if a random employee searches the org catalog and adds `Jose Claude` to a chat with themselves, the bot won't reply to them — the AAD gate blocks it. Catalog visibility is OK; catalog deletion breaks the install.

What to do instead:
- After successful install, **leave the catalog entry alone**. It is visible to org users by name, but the bot ignores everyone except the intended user.
- If you absolutely want to hide it from the org catalog search, the only path is the Teams Admin Center "Block" toggle on the app — which is reversible and does NOT uninstall. Graph API DELETE is destructive.
- When auditing, if a per-user bot is "missing" from the user's Teams, the first hypothesis is "catalog entry was deleted at some point in the past."

If install still 403s after 90+ minutes, then check (in order): token scp claim, catalog entry's `publishingState`, the user's `installedApps` list for a stale install conflict, and finally fall back to chat-scope install or the EdgeBridge workflow.

## Verify token scope before asking Dr. Yoo to re-consent

**Never ask Dr. Yoo to re-consent without first proving the scope is actually missing.** The YooMD delegated grant has been continuously expanded since 2026-04-19 and now covers a wide surface: Chat / Files / Sites / Mail / Calendars / Contacts / User / Group / Directory / AppCatalog / Teams* / AuditLog. Most "I need new scopes" assumptions turn out to be wrong — the scope was already there, but a previous step (token mint failure, expired access token, typo in the `scope=` parameter) hid it.

Concrete example from 2026-05-10: Afrah's install step printed `KeyError: 'access_token'` from a Python json parse. The reflex was "the YooMD refresh token is expired / scope missing — Yoo needs to re-consent." Wrong. Re-minting the token and base64-decoding the `scp` claim showed `AppCatalog.ReadWrite.All` and `TeamsAppInstallation.ReadWriteForUser.All` were both already present. The actual cause was a temp-file race in the script (the python parser read an empty file). Once corrected, install returned 201 first try — no reconsent.

Verified contents of YooMD `scp` claim as of 2026-05-11:
```
AppCatalog.ReadWrite.All AuditLog.Read.All Calendars.ReadWrite Chat.Read Chat.ReadWrite
Contacts.ReadWrite Directory.Read.All Directory.ReadWrite.All Files.Read.All Files.ReadWrite.All
Mail.ReadWrite Mail.Send Sites.Read.All Sites.ReadWrite.All
TeamsAppInstallation.ReadWriteAndConsentForUser TeamsAppInstallation.ReadWriteForChat
TeamsAppInstallation.ReadWriteForUser.All User.Read User.Read.All User.ReadWrite.All
openid profile email
```

Procedure before any "Yoo needs to re-consent" claim:
```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token --query value -o tsv)
TOKEN=$(curl -s -X POST 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token' \
  -d 'client_id=14d82eec-204b-4c2f-b7e8-296a70dab67e' \
  -d 'grant_type=refresh_token' \
  -d "refresh_token=$RT" \
  -d 'scope=<the scope you think you need> offline_access' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("scp:", d.get("scp",""))'
```

If the scope you need is in `scp`, no reconsent. Diagnose elsewhere (token mint failure, script bug, wrong AAD id, etc). Only ask Yoo to re-consent if the JWT genuinely lacks the scope AND the org-wide `oauth2PermissionGrant` for client `14d82eec-204b-4c2f-b7e8-296a70dab67e` doesn't contain it either.

## Installing a bot for a user (Graph + delegated YooMD token)

**Which context are you in?** That changes which approach is right:

| Session context | Auth path |
|---|---|
| Cloud sandbox (this codex-agent repo, no `az` CLI, only proxy) | YooMD delegated refresh token in vault — pattern below |
| Desktop Codex (on Yoo's Mac, has `az` CLI logged in as Yoo) | `az rest` directly — see "Desktop Codex" section below |

**First-line approach (no admin UI needed):** Graph + YooMD delegated token. Pattern (works as of 2026-05-08, after Yoo added the scopes):

```bash
# 1. Get a YooMD delegated token with the right scopes
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token --query value -o tsv)
TOKEN=$(curl -s -X POST 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token' \
  -d 'client_id=14d82eec-204b-4c2f-b7e8-296a70dab67e' \
  -d 'grant_type=refresh_token' \
  -d "refresh_token=$RT" \
  -d 'scope=AppCatalog.ReadWrite.All TeamsAppInstallation.ReadWriteForUser.All offline_access' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

# 2. Install for the user
curl -X POST "https://graph.microsoft.com/v1.0/users/${AAD_OBJECT_ID}/teamwork/installedApps" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/${TEAMS_APP_ID}\"}"
# 201 = installed
```

If a future scope is needed, PATCH the org-wide oauth2PermissionGrant for client `14d82eec-204b-4c2f-b7e8-296a70dab67e` (Microsoft Graph CLI public client) — `consentType: AllPrincipals` — and append the new scope to the `scope` string. Then re-mint the YooMD refresh token to pick up the new scope.

**Fallback when Graph install hits a real wall (tenant policy, scope you can't add, etc):** dispatch the `install-teams-app.yml` workflow in `MSKMSO/Virtual-Machines`. It drives the Teams Admin Center UI through Yoo's EdgeBridge:

```bash
gh workflow run install-teams-app.yml -R MSKMSO/Virtual-Machines \
  -f app_id=<teamsAppId> \
  -f query=<picker-search-string>
gh run watch <run-id>
```

Chain: this sandbox → GitHub Actions runner → OIDC into Azure → pulls bridge URL + token from `SDN-YooVault` → Cloudflare tunnel → Yoo's Mac EdgeBridge → Edge → Teams Admin Center → install. Reports `install verified` on success.

Most common failure: cloudflared tunnel stale on Yoo's Mac. Fix is one `launchctl` bounce, documented in the workflow's playbook.

This requires `gh` CLI access AND a session scoped to dispatch in `MSKMSO/Virtual-Machines`. Codex-Agent-only sessions can't dispatch it — they need to ask the user to launch a properly-scoped session.

## Desktop Codex — use `az rest` directly, no new SP needed

If you're running as Desktop Codex on Yoo's Mac (not the cloud sandbox), the `az` CLI is already logged in as Dr. Yoo (Global Administrator). Don't build a new app registration. Don't create client secrets. Don't run reconsent scripts. Just use `az rest` — it inherits Yoo's delegated token automatically, with these scopes:

`Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.ReadWrite.All`, `Directory.AccessAsUser.All`, `User.ReadWrite.All`, `AuditLog.Read.All`, `DelegatedPermissionGrant.ReadWrite.All`, `Group.ReadWrite.All`.

Verify the scopes any time with:

```bash
az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv \
  | cut -d. -f2 | base64 -d 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('scp',''))"
```

With these scopes Desktop Codex can:

- `az rest --method POST --url https://graph.microsoft.com/v1.0/applications --body '{...}'` — create app registrations
- `.../applications/{id}/addPassword` — mint client secrets (save `secretText`, NEVER `keyId`)
- `.../servicePrincipals` — create SPs
- `.../servicePrincipals/{spId}/appRoleAssignments` — grant any Microsoft Graph application role. With `AppRoleAssignment.ReadWrite.All` already in the token, this call IS the admin consent for app permissions — no browser step, no second user.

Worked example for the Outlook Rules plugin: build app (`signInAudience: AzureADMyOrg`), addPassword, create SP, POST appRoleAssignment for `MailboxSettings.ReadWrite` (role id `6931bccd-447a-43d1-b442-00a195474933` on Microsoft Graph SP `ef405a56-6699-4680-99c6-ed4ee56ee27f`). Four calls, zero browser.

**Do NOT** transplant this pattern into the cloud sandbox session — that session doesn't have Yoo's `az` login, only an OIDC SP. Use the YooMD-refresh-token pattern there.

If you ever need Desktop Codex to keep these powers when Yoo is logged out (headless runs, expired session), the answer is to create a dedicated `Desktop-Codex` SP with the same umbrella perms and client-credentials auth. Don't do this preemptively — only if you hit the case.

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

## Bot Claude auth — token-file fix recipe

Symptom: bots reply "Had trouble generating a reply" or "Your organization does not have access to Claude." When this happens, do NOT start a `claude /login` device-code flow as the first move — try this recipe first.

Root cause: bots share an OAuth account (`yoomd@sdneurosurgery.com`). The token files live at `/etc/claude-tokens/<short>.env`. When one of those files gets emptied or replaced with just the header comment, that specific bot stops responding. A healthy file is ~186–224 bytes; a broken one is ~53–91 bytes (header only, no token).

Fix (no manual sign-in needed if any bot has a healthy token):
1. `ls -la /etc/claude-tokens/*.env` — files under ~100 bytes are broken.
2. Pick any healthy `.env` (e.g. `lia.env`, `cameron.env`) and copy it onto each broken file:
   ```bash
   sudo cp -p /etc/claude-tokens/lia.env /etc/claude-tokens/<short>.env
   ```
3. Restart the affected responder:
   ```bash
   sudo systemctl restart <prefix>-responder.service
   ```
   Filenames use hyphens — `neil-claude.env` not `neilc.env`, `jesus-reyes.env` not `jesusr.env`.
4. Verify with `systemctl is-active <prefix>-responder.service` and a test message in Teams.

If ALL `.env` files are short/missing, the canonical token has expired — that's the only case that requires a manual `claude /login` on the VM as `yoomd@sdneurosurgery.com`. Otherwise this plain file-copy + restart is the fix.

Also verify the maintenance cron is in place:
```bash
sudo crontab -u azureuser -l | grep claude-cred-chmod
```
Re-add if missing:
```
* * * * * /home/azureuser/.claude-cred-chmod.sh >/dev/null 2>&1
```

History: 2026-05-14 — `gabriel.env`, `heather.env`, `kaye.env` were 91 bytes each, fixed by copying from `lia.env` (224 bytes).

## Repo layout

- [`HANDOFF.md`](HANDOFF.md) — the comprehensive reference. Read this first.
- [`README.md`](README.md) — short summary of what Codex Agent is and how it fits into the MSO infrastructure.
- `docs/` — additional reference material (diagnostic scripts, recovery playbooks, model upgrade notes) as the operations grow.
- `patches/` — saved copies of the in-place runtime patches in case the npm package gets overwritten and you need to re-apply them quickly.
