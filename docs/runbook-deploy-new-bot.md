# Runbook — Deploy a new Claude bot for a user

End-to-end procedure for creating a new personal Claude bot for an MSO user. Distilled from deploying Jesus R Claude, Cameron Claude, Ashley Claude on 2026-05-08. Use this every time. The bots-look-fine-but-actually-crashloop bug from 2026-05-09 is encoded here as gotcha #6.

## Audience

Any MSO Claude Code session with:
- The az-run-command proxy in this repo (Codex-Agent) configured
- The OIDC SP `sp-mso-cc-openclaw-diag` with: Bot Service Contributor, User Access Administrator on `SDNeurosurgery-OpenClaw`, plus the Microsoft Graph app permissions granted on 2026-05-07 (`AppCatalog.ReadWrite.All`, `TeamsAppInstallation.ReadWriteForUser.All`)
- Yoo's delegated refresh token at `SDN-YooVault/yoomd-graph-refresh-token` with `AppCatalog.ReadWrite.All` + `TeamsAppInstallation.ReadWriteForUser.All` scopes consented

## Inputs needed from the user (the human asking for the bot)

| Input | Example | Required for |
|---|---|---|
| Full name | `Jesus Reyes` | manifest, descriptions |
| MSO UPN/email | `jesusr@musculoskeletalmso.com` | AAD lookup, make-bot script |
| Display name | `Jesus R Claude` (use first-initial-of-last-name suffix on collision; only one `Jesus` in MSO is unambiguous — there were two, hence `R`) | catalog `name.short` |
| Short name | `jesus-reyes` | filenames, service names, vault keys, nginx paths |
| Title | `RPS Admin PSG` | manifest, system prompt |
| Title prefix `Dr.`? | Yes for Yoo, Heather; no for everyone else seen so far | display name "Dr. Yoo Claude" pattern |

You can compute AAD object id from UPN — don't ask the user for it.

## Pre-flight (one round-trip)

```bash
# Look up the user
az ad user list --filter "startswith(userPrincipalName,'${UPN%@*}')" -o json
# Confirm given/surname, get AAD id
```

Pick a free local port. As of 2026-05-09, used ports were 3977-4000. Use the next free one (`ss -tlnp | grep :4001` should return empty).

## Ordered procedure

### 1. Create AAD app registration (SingleTenant)

```bash
APP_NAME="OpenClaw-${PascalCaseName}Claude"   # e.g. OpenClaw-JesusReyesClaude
az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv
```

**Wait 30s for AAD propagation.** App exists immediately but SP/credential operations against it fail until the directory propagates.

### 2. Create service principal

```bash
az ad sp create --id $APP_ID
# May need retry if AAD still propagating. Retry every 20s up to 6x.
```

### 3. Generate client secret, store in vault

```bash
SECRET=$(az ad app credential reset --id $APP_ID --display-name bot-secret --years 2 --query password -o tsv)

# Store BOTH the secret value and the app id
printf '%s' "$SECRET" | az keyvault secret set --vault-name SDN-YooVault --name ${SHORT}-bot-client-secret --file /dev/stdin -o none
az keyvault secret set --vault-name SDN-YooVault --name ${SHORT}-bot-app-id --value $APP_ID -o none

# Capture secretText, NEVER capture keyId — that's a known footgun (see runbook-rotate-bot-secret.md)
unset SECRET
```

### 4. Create Bot Service resource

**Must use `SingleTenant`. MultiTenant is deprecated and `az bot create` will reject it.**

```bash
az bot create \
  --resource-group SDNeurosurgery-OpenClaw \
  --name "$APP_NAME" \
  --app-type SingleTenant \
  --appid $APP_ID \
  --tenant-id 50186224-2255-444a-b321-60a84114115c \
  --endpoint "https://openclaw-sdneuro.westus2.cloudapp.azure.com/${SHORT}/api/messages" \
  --sku F0 \
  --description "${USER_FULL}'s Personal Claude Agent"
```

### 5. Enable Microsoft Teams channel

```bash
az bot msteams create -g SDNeurosurgery-OpenClaw -n "$APP_NAME"
```

Default channels are only `webchat` + `directline`. Without this step, Teams cannot deliver messages to the bot.

### 6. Wait 30s. Test BF token end-to-end.

```bash
curl -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode "client_id=$APP_ID" \
  --data-urlencode "client_secret=$SECRET" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'scope=https://api.botframework.com/.default' \
  | jq '.access_token != null'
# expect: true
```

### 7. Build Teams app zip

Use `aixa-teams-app/color.png` + `outline.png` as default icons unless the user provides custom. Manifest must have:

- `id`: fresh UUID (`uuid.uuid4()`)
- `manifestVersion`: `"1.16"`
- `version`: `"1.0.0"`
- `name.short`: the display name (e.g. `"Jesus R Claude"`)
- `name.full`: `"<Full Name> Claude"`
- `bots[0].botId`: the new AAD app id
- `bots[0].scopes`: `["personal", "groupChat", "team"]`
- `validDomains`: `["openclaw-sdneuro.westus2.cloudapp.azure.com"]`

Save copies in:
- `/home/azureuser/${SHORT}-teams-app/manifest.json` (plus color.png + outline.png)
- `/home/azureuser/${SHORT}-teams-app.zip`

### 8. Upload to Teams catalog → get catalog id

```bash
TOKEN=$(/home/azureuser/yoomd-appcatalog-token.sh)
RESP=$(curl -X POST "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?requiresReview=false" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @/home/azureuser/${SHORT}-teams-app.zip)
CAT_ID=$(echo "$RESP" | jq -r .id)
# expect 201 Created
```

### 9. Wait 90s for AAD throttling to clear before make-bot

Make-bot script does its own AAD lookup which can throttle right after the bursty operations above.

### 10. Run make-mso-claude-bot.sh AS azureuser

**Critical: run as `azureuser`, not `root`. If run as root, the home dir `~/.${SHORT}-bot/` and its `creds.json` end up owned by root, the bot service runs as azureuser and can't read its own creds, and it enters a silent restart loop that `systemctl is-active` reports as `active` ~40% of the time (the bug that fooled MSO Claude on 2026-05-09).**

```bash
sudo -u azureuser bash /home/azureuser/make-mso-claude-bot.sh \
  --short "$SHORT" \
  --full "$USER_FULL" \
  --title "$TITLE" \
  --upn "$UPN" \
  --port "$PORT" \
  --app-id "$APP_ID" \
  --teams-catalog "$CAT_ID" \
  --bot-name "$DISPLAY_SHORT"
```

If you accidentally ran it as root (or via az-run-command which runs as root by default), fix with:

```bash
sudo chown -R azureuser:azureuser /home/azureuser/.${SHORT}-bot/
sudo systemctl restart ${SHORT}-bot.service ${SHORT}-responder.service
```

### 11. Patch known template bugs in the responder

The template has historically shipped with two bugs. Check + fix:

```bash
F=/home/azureuser/${SHORT}-responder.py

# Bug 1: duplicate _post_reply_orig_protect definition (infinite recursion).
# Older template versions had this; newer don't. Safe to run either way.
python3 -c "
import re
src = open('$F').read()
src, n = re.subn(r'^def _post_reply_orig_protect\(chat_id, text\):\n    return _post_reply_orig_protect\(chat_id, _redact_passwords_protect\(text\)\)\n', '', src, flags=re.MULTILINE)
open('$F','w').write(src)
print(f'removed {n} duplicate def(s)')
"

# Bug 2: allow-list excludes Dr. Yoo. Without him, only the bot's owner can ever test.
python3 -c "
import re
src = open('$F').read()
src = re.sub(r'^USER_AAD_ID = (\".*\")$',
             r'USER_AAD_ID = \1\nYOO_AAD_ID = \"e0d48eb4-1eb3-4263-a72e-f6ad4ef32238\"',
             src, flags=re.MULTILINE)
src = re.sub(r'frm\.get\(\"aadObjectId\", \"\"\) != USER_AAD_ID',
             'frm.get(\"aadObjectId\", \"\") not in (USER_AAD_ID, YOO_AAD_ID)',
             src)
open('$F','w').write(src)
"

sudo systemctl restart ${SHORT}-responder.service
```

### 12. Install for the user via Graph

```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token --query value -o tsv)
TOKEN=$(curl -s -X POST 'https://login.microsoftonline.com/organizations/oauth2/v2.0/token' \
  -d 'client_id=14d82eec-204b-4c2f-b7e8-296a70dab67e' \
  -d 'grant_type=refresh_token' \
  -d "refresh_token=$RT" \
  -d 'scope=AppCatalog.ReadWrite.All TeamsAppInstallation.ReadWriteForUser.All offline_access' \
  | jq -r .access_token)

curl -X POST "https://graph.microsoft.com/v1.0/users/${USER_AAD_ID}/teamwork/installedApps" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/${CAT_ID}\"}"
# expect 201 Created
```

If you get **403 Forbidden with "App is blocked by app permission policy"** — the most likely cause is **missing scopes on the token, NOT a tenant policy**. Verify the token actually has both scopes (decode the JWT, or check `scope` returned by the token endpoint). The 2026-05-08 incident burned 2 hours chasing the policy hypothesis when the fix was adding scopes to the YooMD oauth2PermissionGrant.

**Fallback if Graph install genuinely cannot work**: dispatch `install-teams-app.yml` in `MSKMSO/Virtual-Machines` (UI-automation via EdgeBridge). See `AGENTS.md` for the full pattern.

### 13. Delete from catalog (private mode)

The bot is now installed for the user. Delete the catalog entry so it isn't searchable by other org members.

```bash
curl -X DELETE "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/${CAT_ID}" \
  -H "Authorization: Bearer $TOKEN"
# expect 204 No Content
```

### 14. Verify with bot-health-check.sh — NOT systemctl is-active

```bash
bash /home/azureuser/bot-health-check.sh $SHORT
# expect exit 0, JSON with healthy: true and all 7 checks "pass"
```

**Do not stop here if `systemctl is-active` says active. That signal lies during crash loops.** The helper enforces seven gates including dir ownership (catches the root-owned-creds bug) and uptime ≥ 30s (catches the crash loop). Only `bash bot-health-check.sh` with exit 0 = bot is actually serving traffic.

If any gate fails, fix and re-verify before reporting done.

## Gotchas (failure modes observed)

| Symptom | Likely cause | Fix |
|---|---|---|
| `az ad sp create` returns "does not exist" right after app create | AAD propagation | Wait 30s, retry |
| `az bot create` returns "Multitenant bot creation is deprecated" | Wrong `--app-type` | Use `SingleTenant` + `--tenant-id` |
| `make-mso-claude-bot.sh` fails with "Temporarily throttled" at user lookup | AAD throttling from bursty operations | Wait 90s, retry |
| Bot reports active but doesn't reply, no errors logged | Crash loop from root-owned creds | `chown -R azureuser:azureuser ~/.${SHORT}-bot/`, restart |
| 403 on install with "blocked by app permission policy" | Missing scope on YooMD token | Add scope to oauth2PermissionGrant for client `14d82eec-...`, re-mint token. NOT a tenant policy. |
| `403 AADSTS7000215: Invalid client secret` | `creds.json` has secret ID not secret value | See `runbook-rotate-bot-secret.md` |
| Vault secret is ~270 chars not 40 | `az` CLI warning got concatenated into the stored value | `tail -n 1` extracts the real 40-char secret. Write back. |
| Bot exists but never receives any inbound | Microsoft URL mismatch (e.g. `/foo/api/messages` vs `/foo-claude/api/messages`) | `az resource update` on the Bot Service resource to fix `properties.endpoint`. |

## After-deployment checklist

- [ ] `bot-health-check.sh` returns exit 0 with all 7 checks pass
- [ ] Test message from owner returns a reply within 5s
- [ ] Test message from Dr. Yoo returns a reply within 5s (proves allow-list patch landed)
- [ ] Catalog entry is gone (`curl -o /dev/null -w '%{http_code}' .../appCatalogs/teamsApps/$CAT_ID` returns 404)
- [ ] Bot is in the user's Teams personal app rail

## References

- `/home/azureuser/make-mso-claude-bot.sh` — VM-side template stamper
- `/home/azureuser/yoomd-appcatalog-token.sh` — minted AppCatalog.ReadWrite.All token
- `/home/azureuser/yoomd-graph-token.sh` — minted broader YooMD delegated token
- `/home/azureuser/bot-health-check.sh` — 7-check health verifier (use this, not is-active)
- `docs/multi-bot-debugging.md` — when a deployed bot misbehaves
- `docs/runbook-rotate-bot-secret.md` — rotating the secret
- `MSKMSO/Virtual-Machines/install-teams-app.yml` — UI-automation fallback for install
