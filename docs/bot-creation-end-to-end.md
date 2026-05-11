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
