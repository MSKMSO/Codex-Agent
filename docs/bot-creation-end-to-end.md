# Creating a new personal Claude bot — end-to-end playbook

This is the canonical sequence for "Dr. Yoo wants a new bot for <user>." Follow it top-to-bottom. **Don't reorder, don't skip preflight, don't improvise.** Every step has a verify gate; if a gate fails, stop and escalate — do not retry.

The 2026-05-11 incident (Jose / Axel / Lia / Afrah Claude bots stuck for hours behind Microsoft's tenant policy gate, with MSO Claude making the problem worse by repeatedly retrying) is the failure mode this playbook prevents.

---

## Inputs you need before starting

- **Bot short-name**: `<name>` (lowercase, used for service names, dir names, file prefixes — e.g. `cameron`, `ashley`, `jesus-reyes`)
- **Bot display name**: the Teams catalog name (e.g. `Cameron Claude`, `Ashley Claude`). **Pick ONCE. Never change it.** Renames force re-upload which triggers anti-abuse.
- **Target user UPN**: e.g. `Cameronp@musculoskeletalmso.com`
- **Target user AAD object id**: look up via `GET /v1.0/users/{upn}?$select=id`
- **Bot description** (≤80 chars): goes in the manifest

---

## PHASE 0 — Preflight (≤2 minutes, mandatory)

Before doing anything that creates state, run these checks. If any fails, **stop** and escalate to Dr. Yoo. Do not proceed in the hope it'll work anyway.

### 0.1 — Is the Teams app permission policy actually open right now?

The single biggest cause of "bot built but can't install" today is the tenant Teams app permission policy quietly blocking `AppType: Private` (custom uploaded apps). Microsoft sometimes flips this default; admins sometimes flip it too. **Check before you upload.**

Probe: do a dry-run install of an EXISTING working bot to a test user who already has it (Dr. Yoo). If that returns 200 OK or "already installed" (409 with `Conflict` body containing `installationId`), the gate is open. If it returns 403 `App is blocked by app permission policy`, the gate is closed — stop, escalate, do not build the new bot today. The whole pipeline is broken.

```bash
# pseudo:
curl -X POST /v1.0/users/{yoo-id}/teamwork/installedApps \
  -d '{"teamsApp@odata.bind":"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/{any-working-claude-app-id}"}'
# 200/409 → policy open. 403 → policy closed, ABORT.
```

### 0.2 — Has the AppPublisher identity been used recently?

Check that `SDN-YooVault/yoomd-graph-refresh-token-appcatalog` mints cleanly:

```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token-appcatalog --query value -o tsv)
curl -X POST .../token -d "client_id=9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6&grant_type=refresh_token&refresh_token=$RT&scope=AppCatalog.ReadWrite.All offline_access"
# expect: 200 with access_token
```

If 401/403, the refresh token has expired (90-day idle) and Dr. Yoo needs to re-consent. Escalate.

### 0.3 — Is the VM healthy?

Run `scripts/bot-health-check.sh` against any existing working bot (e.g., `cameron`). If that bot reports `healthy: true`, the VM infrastructure is fine. If it fails, fix the existing bot first — don't pile a new bot on top of a broken base.

---

## PHASE 1 — Microsoft Entra app + Bot Service registration

### 1.1 — Create the Entra app registration

```bash
# Using VM managed identity for Graph (has Application.ReadWrite.All):
APP_RESP=$(az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/applications" \
  --headers "Content-Type=application/json" \
  --body '{"displayName":"<Bot Display Name>","signInAudience":"AzureADMyOrg"}')
APP_ID=$(echo "$APP_RESP" | jq -r .appId)
APP_OBJ=$(echo "$APP_RESP" | jq -r .id)
```

### 1.2 — Mint the client secret

**CRITICAL: save `secretText`, not `keyId`.** This trapped the 2026-05-07 fix.

```bash
SECRET_RESP=$(az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/applications/$APP_OBJ/addPassword" \
  --headers "Content-Type=application/json" \
  --body '{"passwordCredential":{"displayName":"v1","endDateTime":"<now+1yr ISO>"}}')
SECRET_VALUE=$(echo "$SECRET_RESP" | jq -r .secretText)  # NOT .keyId. NEVER .keyId.
[ -n "$SECRET_VALUE" ] && [ "$SECRET_VALUE" != "null" ] || { echo "FAIL: no secretText"; exit 1; }
```

### 1.3 — Create the SP for the app

```bash
az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals" \
  --body "{\"appId\":\"$APP_ID\"}"
```

### 1.4 — Create the Azure Bot Service resource

```bash
az bot create -g SDNeurosurgery-OpenClaw \
  -n "OpenClaw-<NameClaude>" \
  --app-type SingleTenant \
  --appid "$APP_ID" \
  --tenant-id 50186224-2255-444a-b321-60a84114115c \
  --endpoint "https://openclaw-sdneuro.westus2.cloudapp.azure.com/<name>/api/messages" \
  --sku F0 \
  --display-name "<Bot Display Name>"
```

### 1.5 — Enable the Teams channel

```bash
az bot msteams create -g SDNeurosurgery-OpenClaw -n "OpenClaw-<NameClaude>"
```

### 1.6 — Verify-after-create

```bash
az bot show -g SDNeurosurgery-OpenClaw -n "OpenClaw-<NameClaude>" --query properties.endpoint
az bot msteams show -g SDNeurosurgery-OpenClaw -n "OpenClaw-<NameClaude>" --query properties.isEnabled
# Both should return non-null / true. If not, STOP.
```

---

## PHASE 2 — VM service files

### 2.1 — Drop the bot code on the VM as `azureuser`, not root

**This is the bug from 2026-05-09.** Provisioning scripts that run `sudo` and forget to `chown` back leave files owned by `root`, and the bot service (running as `azureuser`) can't read its own creds. The service then crash-loops every 5 seconds while `systemctl is-active` lies that it's running.

```bash
# Run the deploy as azureuser, NOT as root:
sudo -u azureuser bash -lc '
  mkdir -p /home/azureuser/.<name>-bot
  cat > /home/azureuser/.<name>-bot/creds.json <<JSON
{"app_id":"<APP_ID>","client_secret":"<SECRET_VALUE>","tenant":"<TENANT_ID>"}
JSON
  chmod 600 /home/azureuser/.<name>-bot/creds.json
'
```

If you must do part of it as root, end every block with `sudo chown -R azureuser:azureuser /home/azureuser/.<name>-bot /home/azureuser/<name>-*`.

### 2.2 — Generate bot.py and responder.py from a template

Use the latest WORKING bot's source as the template. Examples: `cameron-bot.py`, `cameron-responder.py`. **Read them first, don't write fresh.**

Substitute:
- `USER_AAD_ID = "<target user's AAD object id>"`
- Bot name strings
- Port (allocate a fresh one — check `ss -tlnp` for what's in use)

**Critical**: after substitution, `diff` the new responder against the template. Confirm only the substituted fields differ. **No duplicate function definitions** — the 2026-05-07 recursion bug was a copy-paste that doubled `_post_reply_orig_protect`.

### 2.3 — systemd units

Create `/etc/systemd/system/<name>-bot.service` and `<name>-responder.service`. Use existing working bot's unit as template. Common gotcha: the unit's `User=` line must be `azureuser`, not root.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now <name>-bot.service <name>-responder.service
```

### 2.4 — nginx route

Add the location block to `/etc/nginx/sites-enabled/openclaw-sdneuro`:

```
location /<name>/api/messages { proxy_pass http://127.0.0.1:<port>/api/messages; ... }
```

`sudo nginx -t && sudo systemctl reload nginx`.

### 2.5 — Verify-after-deploy

**Run `bash /home/azureuser/bot-health-check.sh <name>`. All 7 gates must pass.** If any fail, fix before continuing. See `docs/multi-bot-debugging.md` for the gate-by-gate fix list.

---

## PHASE 3 — Teams catalog publish

### 3.1 — Generate manifest

Build the manifest zip with a **fresh externalId UUID** (never reuse one — duplicates cause publish conflicts). Use an existing working bot's manifest as the template.

### 3.2 — Upload — ONCE — via AppPublisher identity

**Not the YooMD chat token.** Per `docs/teams-app-publishing.md` Rule 0:

```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token-appcatalog --query value -o tsv)
APPCAT_TOKEN=$(curl -X POST .../token \
  -d "client_id=9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6&grant_type=refresh_token&refresh_token=$RT&scope=AppCatalog.ReadWrite.All offline_access" \
  | jq -r .access_token)

UPLOAD=$(curl -X POST "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps" \
  -H "Authorization: Bearer $APPCAT_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @manifest.zip)
TEAMS_APP_ID=$(echo "$UPLOAD" | jq -r .id)
```

### 3.3 — Verify publish (mandatory poll)

```bash
for i in {1..30}; do
  STATUS=$(curl -sS -o /tmp/r -w '%{http_code}' \
    -H "Authorization: Bearer $APPCAT_TOKEN" \
    "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$TEAMS_APP_ID")
  [ "$STATUS" = "200" ] && { echo "published"; break; }
  sleep 10
done
[ "$STATUS" = "200" ] || { echo "QUARANTINED — STOP — DO NOT RETRY"; exit 1; }
```

If verify fails after 5 minutes, the app got quarantined by Microsoft. **Stop. Don't re-upload.** Each new upload deepens the cooldown. Write a handoff, escalate.

---

## PHASE 4 — Install for the target user

### 4.1 — Use YooMD chat token, not AppPublisher

The install endpoint requires `TeamsAppInstallation.ReadWriteForUser.All`, which AppPublisher doesn't have but YooMD does.

```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token --query value -o tsv)
CHAT_TOKEN=$(curl -X POST .../token \
  -d "client_id=14d82eec-204b-4c2f-b7e8-296a70dab67e&grant_type=refresh_token&refresh_token=$RT&scope=TeamsAppInstallation.ReadWriteForUser.All offline_access" \
  | jq -r .access_token)

curl -X POST "https://graph.microsoft.com/v1.0/users/$TARGET_AAD_ID/teamwork/installedApps" \
  -H "Authorization: Bearer $CHAT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$TEAMS_APP_ID\"}"
# Expect: 201 Created
```

### 4.2 — Verify install record

```bash
curl -G "https://graph.microsoft.com/v1.0/users/$TARGET_AAD_ID/teamwork/installedApps" \
  -H "Authorization: Bearer $CHAT_TOKEN" \
  --data-urlencode '$expand=teamsApp' \
  | jq ".value[] | select(.teamsApp.id == \"$TEAMS_APP_ID\") | .teamsApp.displayName"
# Expect: prints the bot's display name. If empty, the install didn't take.
```

---

## PHASE 5 — End-to-end health check

Final gate before you report success:

1. **`bot-health-check.sh`** returns `healthy: true` for the new bot
2. **Test message via `<name>-send-to.sh`** to the target user (the bot's own send-helper) — expect HTTP 201
3. **Read activities log** after the user sends a `hello` — `tail /home/azureuser/.<name>-bot/activities.jsonl` should show the inbound message within 30s

If steps 1+2+3 all pass, the bot is live. Report 4-field summary to Dr. Yoo.

If step 3 fails (no inbound message logged), the user didn't actually message yet OR there's a Microsoft → bot delivery problem. Don't claim success. Wait for confirmation.

---

## PHASE 6 — Wire Dr. Yoo's identifier access (Tier 1 vs Tier 2)

Every bot in the fleet gets access to Dr. Yoo's professional identifiers (NPI, CA medical license, practice address, mailing address, office phone, work email, practice org). This lets bots pre-fill vendor consulting agreements, hospital credentialing forms, Sunshine Act / Open Payments forms, insurance provider sections, CME registration, etc. — without re-asking Dr. Yoo every time.

The single source of truth is `SDN-YooVault` → secret `dr-yoo-identifiers` (JSON). Edit the repo file `MSKMSO/Virtual-Machines/scripts/dr-yoo-identifiers.json`, then run workflow `kv-set-dr-yoo-identifiers.yml` to push the new value into the vault.

### Tier decision tree

| Bot belongs to | Tier | Where the identifiers live |
|---|---|---|
| Dr. Frank Kevin Yoo or Dr. Heather Yoo (personal agents) | **Tier 1** | Hardcoded in the responder source via marker `DR_YOO_IDENTIFIERS_V1` |
| Anyone else — staff, organizational, persona, or third-party bot | **Tier 2** | Fetched from Key Vault on service startup via marker `DR_YOO_IDENTIFIERS_V2_VAULT` |

There are only three Tier 1 bots and there will never be more: Dr. Yoo's Anthropic Agent (`yooanthropic-responder`), Dr. Yoo's OpenAI Agent (`yooopenai-responder`), Dr. Heather's AI Agent (`heather-responder`). Every new bot you create is Tier 2.

### Tier 1 wiring (for the rare case of building Dr. Yoo's or Dr. Heather's next personal agent)

Use `MSKMSO/Virtual-Machines/scripts/tier1-embed-identifiers.py` via workflow `tier1-embed-identifiers.yml`. It:

1. Reads the JSON from `/home/azureuser/dr-yoo-identifiers.json` on the VM (a legacy artifact still present for Tier 1 — do not remove).
2. For each service in `SERVICES`, finds the responder `.py` via `systemctl show … -p ExecStart`.
3. Locates the first system-prompt-style variable (`SYSTEM_BASE`, `SYSTEM_PROMPT`, etc.) and appends the identifier block via a rebinding statement at end of file.
4. py_compile-checks the new file, backs up `.bak-<ts>`, atomic-replaces, `systemctl restart`.

Add the new service name to `SERVICES` in `tier1-embed-identifiers.py`. Dispatch the workflow. It is idempotent (marker `DR_YOO_IDENTIFIERS_V1` prevents re-injection).

**Tradeoff:** Tier 1 needs a code redeploy + restart to pick up a new identifier value. Acceptable because NPI / license / addresses change rarely.

### Tier 2 wiring (the default — every new bot)

#### 2a. For Python responders (the templated bots — Ashley, Cameron, all staff bots, etc.)

Use `MSKMSO/Virtual-Machines/scripts/tier2-wire-vault-fetch.py` via workflow `tier2-wire-vault-fetch.yml`. It:

1. Confirms the VM managed identity can read `SDN-YooVault → dr-yoo-identifiers` (it has Key Vault Administrator).
2. For each service in `SERVICES`, finds the responder `.py` via `systemctl show`.
3. Injects two pieces:
   - After the last `import` line: a `_dr_yoo_block()` helper that shells out to `az keyvault secret show … dr-yoo-identifiers` at module load, caches via `lru_cache`, returns the formatted identifier block. Returns `""` on any failure so the bot keeps working.
   - At end of file: `<varname> = <varname> + "\n\n" + _dr_yoo_block()`.
4. py_compile + atomic replace + `systemctl restart`.

Add the new bot's responder service name (e.g. `<name>-responder`) to the `SERVICES` list. Dispatch the workflow. Marker `DR_YOO_IDENTIFIERS_V2_VAULT` makes it idempotent.

**Per-user account note:** if the bot runs as its own Linux user (the per-user bot pattern — Jose, Axel, Lia, Afrah, etc.), that user must have `az login --identity` configured. The provisioning script for per-user bots already does this. The VM MI has Key Vault Administrator regardless of which Linux user calls `az`.

#### 2b. For openclaw runtime bots (Codex specifically — and any future openclaw-based bot)

These don't have a Python responder file to patch. The behavioral policy is in workspace policy files (`IDENTITY.md`, `SOUL.md`, `USER.md`, `MEMORY.md`) that bootstrap reads at session start. The pattern is:

1. Install a fetcher script at `/home/azureuser/.<bot>-fetch-identifiers.sh` that runs `az keyvault secret show` and writes `<workspace-dir>/DR_YOO_IDENTIFIERS.md` from the JSON.
2. Add `ExecStartPre=/home/azureuser/.<bot>-fetch-identifiers.sh` to the bot's systemd unit (idempotent — only insert once).
3. Run the fetcher once to populate the workspace file.
4. `systemctl daemon-reload && systemctl restart <bot>`.

Reference implementation: `MSKMSO/Codex-Agent/scripts/wire-tier2-dr-yoo-identifiers.sh` (used to wire `openclaw-codex.service`).

**Common gotcha:** if you run the fetcher manually as root the first time, the workspace file is owned by root and the service (running as `azureuser`) can't overwrite it on its next restart — ExecStartPre fails and the bot crash-loops. Always `chown azureuser:azureuser <workspace-dir>/DR_YOO_IDENTIFIERS.md` after the first manual run.

### What the identifier block says (always, every bot)

The block embedded/fetched into the system prompt includes:

- Legal name, preferred name, specialty
- NPI, CA medical license
- Practice address, mailing address
- Office phone, work email, practice org

And it includes an explicit refusal list — every bot must refuse to fill: bank routing/account numbers, credit card numbers, SSN, EIN/tax IDs, DEA registration, date of birth, driver's license, passwords, signatures.

### Verifying after wiring

Send the bot a test message in Teams: *"What's Dr. Yoo's NPI?"* — it should answer `1295774545` without prompting. If it asks Dr. Yoo for the number, the wiring didn't apply — check:

1. `systemctl is-active <name>-responder` — service running?
2. `grep DR_YOO_IDENTIFIERS_V2_VAULT <path-to-responder.py>` — marker present?
3. For Tier 2: `sudo -u <user> az keyvault secret show --vault-name SDN-YooVault --name dr-yoo-identifiers --query id -o tsv` — vault reachable from that user account?

### When you update the identifier values

1. Edit `MSKMSO/Virtual-Machines/scripts/dr-yoo-identifiers.json`, commit, push.
2. Run workflow `kv-set-dr-yoo-identifiers.yml` to push to the vault.
3. **Tier 2 bots:** restart each service — `systemctl restart <name>-responder`. The lru_cache forces a fresh fetch on next launch.
4. **Tier 1 bots:** run `tier1-embed-identifiers.yml`. The marker check skips already-embedded files unless you bump the marker version. To force a refresh, either bump the marker (`V1` → `V2`) in the script or hand-remove the marker block from each Tier 1 responder first.

### Bots that get NEITHER tier

None, currently. Tier 2 covers every authorized bot in the fleet. If you ever want to wall a bot off from Dr. Yoo's identifiers, the way to enforce that is to NOT add its responder service to `tier2-wire-vault-fetch.py`'s `SERVICES` list — the vault is open to any Linux account on the VM that has `az login --identity`, so scope is enforced by which responder code contains the fetcher.

---

## Failure-mode map (what each error code actually means)

| Symptom | Cause | Fix |
|---|---|---|
| Upload returns 201, GET returns 404 | Microsoft anti-abuse quarantine (you've uploaded too many times today) | STOP. Wait 24h. Do not retry. |
| Upload returns 409 Conflict | Same externalId already in catalog. The conflict body has the existing app id | Use the returned id; don't re-upload |
| Install returns 403 `blocked by app permission policy / AppType: Private` | Tenant Teams app permission policy blocks Private apps | Drive Teams Admin Center UI via EdgeBridge (see `reference_teams_app_install_admin_ui.md` in user memory) |
| Install returns 403 with NO message body | Token missing `TeamsAppInstallation.ReadWriteForUser.All` scope | Use the YooMD chat token, not AppPublisher |
| `bot-health-check.sh` shows `dir_owner: fail:root` | Provisioning ran as root | `chown -R azureuser:azureuser ~/.bot-dir ~/bot-files-*` |
| `bot-health-check.sh` shows `bf_auth: fail:HTTP-401` | `creds.json` has the secret ID instead of the secret value | Rotate per `docs/runbook-rotate-bot-secret.md` |
| `bot-health-check.sh` shows `uptime_bot: fail:Ns<30s` and `restarts_bot: fail:N/2min` | Bot is in crash loop | `journalctl -u <name>-bot.service -n 30` for the actual exception |

---

## Anti-patterns to never do

- **Delete-and-reupload to fix a manifest bug.** Use `POST /teamsApps/{id}/appDefinitions` for version bumps.
- **Retry an install that returned 403.** First verify the app exists with `GET /teamsApps/{id}`.
- **Trust `systemctl is-active`.** It's true ~30-50% of the time during crash loops. Use `bot-health-check.sh`.
- **Use the YooMD chat token for catalog uploads.** Use AppPublisher.
- **Skip the preflight policy check.** Build-then-install when the gate is closed wastes hours and leaves orphan state.
- **Mint a new client_secret without saving it to the vault as a backup first.** Lost secrets can't be recovered, only rotated.

---

## RECOVERY — When a previous publish got quarantined

When Phase 3.3's verify poll returns 404 and you've confirmed the upload was silently quarantined, the original externalId is now poisoned. Microsoft remembers it well enough to reject re-uploads (409) but won't surface it for use (404). The cooldown clears in roughly 24 hours, but you can publish a working bot **today** by giving the user a **new Teams app** that has nothing to do with the quarantined one.

The cooldown is keyed on **externalId**, NOT on displayName, NOT on botId, NOT on the Linux service. So:

- Generate a **fresh externalId UUID** (`uuidgen | tr 'A-Z' 'a-z'`). Microsoft has no record of it; the new upload sails through.
- **Keep the same `displayName`** (e.g. "Kaye Claude"). Microsoft does not deduplicate by displayName.
- **Keep the same `botId`** (the existing Entra appId). The bot service, the Linux user, and the responder don't change at all — this is purely a catalog-side recovery.

```bash
# Generate fresh externalId for the recovery manifest
NEW_EXT=$(uuidgen | tr 'A-Z' 'a-z')

# Build manifest.zip with NEW externalId, same displayName, same botId
python3 - <<PY
import json
m = json.load(open('manifest.json'))
m['id'] = "$NEW_EXT"      # fresh externalId
# All other fields unchanged: name, description, botId, accentColor, icons...
json.dump(m, open('manifest.json','w'), indent=2)
PY
zip -j recovery.zip manifest.json color.png outline.png

# Upload once via AppPublisher (Phase 3.2 rules still apply)
APP_PUBLISHER_TOK=$(...)
RESP=$(curl -sS -X POST https://graph.microsoft.com/v1.0/appCatalogs/teamsApps \
  -H "Authorization: Bearer $APP_PUBLISHER_TOK" \
  -H "Content-Type: application/zip" \
  --data-binary @recovery.zip)
RECOVERY_ID=$(jq -r .id <<< "$RESP")

# Verify (Phase 3.3 verify gate STILL applies — the new externalId could
# also fail if MSO is in a tenant-wide cooldown, but that's rare)
for i in $(seq 1 30); do
  STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
    "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$RECOVERY_ID" \
    -H "Authorization: Bearer $APP_PUBLISHER_TOK")
  [ "$STATUS" = "200" ] && { echo "recovered"; break; }
  sleep 10
done
```

**DO NOT** delete the quarantined original. Leaving it alone causes no harm — without an active Entra app behind it, it does nothing. **Deleting it adds to Microsoft's anti-abuse counter and can deepen the cooldown for the entire tenant.** The orphan will eventually clear on Microsoft's side; we ignore it.

**DO NOT** reuse the quarantined externalId for any future re-upload of any bot. That UUID is dead forever from Microsoft's deduplication perspective.

After the recovery upload is verified (200 from GET), proceed to Phase 4 (Install) and Phase 5 (Health check) as normal, using `RECOVERY_ID` everywhere a teamsApp.id is needed.

---

## Identifier glossary (so you don't confuse them)

Microsoft uses the same field name `"id"` in different POST responses to mean different things. Confusion here is what trapped the Kaye recovery on 2026-05-14.

| Term | Where it lives | Shape | What it identifies |
|---|---|---|---|
| **Entra appId** / Microsoft App ID | Entra app registration | UUID | The bot's auth identity (Bot Framework JWT) |
| **botId** | Manifest's `bots[0].botId` | UUID | Same value as Entra appId, prefixed in conversations as `28:<appId>` |
| **teamsApp.id** | `GET /v1.0/appCatalogs/teamsApps/{id}` | UUID | The catalog-side identifier. Generated by Microsoft when the manifest is POSTed. **Different** from Entra appId. |
| **externalId** | `manifest.json`'s top-level `id` field | UUID | The identifier YOU put in the manifest. Microsoft deduplicates uploads on this. Locked forever after first successful publish. |
| **entitlementId** | `GET /v1.0/users/{aad}/teamwork/installedApps[].id` | base64 string | An install record. The `"id"` in install-side POST responses confusingly returns this, not the teamsApp.id. |
| **AAD Object ID** | Entra user object | UUID | A user's directory id. Goes in `ALLOWED_AAD_OIDS` on the per-bot env file. |

**Quick disambiguation:** if a UUID 404s on `GET /v1.0/appCatalogs/teamsApps/{id}` and resolves on `GET /v1.0/users/{aad}/teamwork/installedApps/{id}`, it's an entitlementId, not a teamsApp.id. The recovery procedure above won't work against an entitlementId — you need the actual teamsApp.id (often surfaced in a 409 Conflict body when a duplicate upload is attempted).

---

## Bot returns "Had trouble generating a reply"

Different problem from anything above. The bot publish succeeded and the user CAN reach it, but every reply is an error. See [`bot-empty-reply-diagnosis.md`](bot-empty-reply-diagnosis.md) — it walks through the three patterns (rate limit, broken `run_codex` from code injection, Graph 404 red herring) and exactly which logs distinguish them.
